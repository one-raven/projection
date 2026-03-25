pub mod protocol;

use crate::protocol::{intent_envelope, reader_loop, ready_envelope, writer_loop};
use serde_json::Value;
use serde_json::json;
use slint::ComponentHandle;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread;

pub use crate::protocol::{
    ELIXIR_TO_UI_CAP, ElixirEnvelope, PatchOp, UI_TO_ELIXIR_CAP, UiEnvelope,
    ready_envelope_with_reason,
};
pub use serde_json;

const DEFAULT_UI_OUTBOUND_QUEUE_CAP: usize = 256;

pub trait HostBindings {
    type Ui: ComponentHandle + 'static;
    type ScreenId: Copy + Default + Send + 'static;

    fn new_ui() -> Result<Self::Ui, slint::PlatformError>;

    fn bind_bridge_intent<F>(ui: &Self::Ui, handler: F)
    where
        F: Fn(String, String) + Send + 'static;

    fn bind_ui_intent<F>(ui: &Self::Ui, handler: F)
    where
        F: Fn(String, String) + Send + 'static;

    fn bind_navigate<F>(ui: &Self::Ui, handler: F)
    where
        F: Fn(String, String) + Send + 'static;

    fn set_app_title(ui: &Self::Ui, title: &str);
    fn set_active_screen(ui: &Self::Ui, active_screen: &str);
    fn set_nav_can_back(ui: &Self::Ui, nav_can_back: bool);
    fn set_error_title(ui: &Self::Ui, title: &str);
    fn set_error_message(ui: &Self::Ui, message: &str);
    fn set_error_screen_module(ui: &Self::Ui, screen_module: &str);

    fn apply_screen_render(ui: &Self::Ui, vm: &Value) -> Result<Self::ScreenId, String>;

    fn apply_screen_patch(
        ui: &Self::Ui,
        screen_id: Self::ScreenId,
        ops: &[PatchOp],
        vm: &Value,
    ) -> Result<(), String>;

    fn apply_app_render(_ui: &Self::Ui, _vm: &Value) -> Result<(), String> {
        Ok(())
    }

    fn apply_app_patch(
        _ui: &Self::Ui,
        _ops: &[PatchOp],
        _vm: &Value,
    ) -> Result<(), String> {
        Ok(())
    }

    fn patch_changes_screen(path: &str) -> bool {
        path == "/screen/name"
    }
}

#[derive(Debug, Clone)]
pub struct UiModelState<ScreenId: Copy + Default> {
    pub screen_id: ScreenId,
    pub vm: Value,
    pub last_rev: Option<u64>,
    pub last_ack: Option<u64>,
}

impl<ScreenId: Copy + Default> Default for UiModelState<ScreenId> {
    fn default() -> Self {
        Self {
            screen_id: ScreenId::default(),
            vm: Value::Object(serde_json::Map::new()),
            last_rev: None,
            last_ack: None,
        }
    }
}

pub fn run<B: HostBindings>() -> Result<(), Box<dyn std::error::Error>> {
    let ui = B::new_ui()?;
    let ui_weak = ui.as_weak();
    let ui_model_state = Arc::new(Mutex::new(UiModelState::<B::ScreenId>::default()));
    let next_intent_id = Arc::new(AtomicU64::new(1));
    let dropped_intent_count = Arc::new(AtomicU64::new(0));
    let resync_pending = Arc::new(AtomicBool::new(false));
    let outbound_queue_cap = parse_outbound_queue_capacity();
    let (tx, rx) = mpsc::sync_channel(outbound_queue_cap);
    let sid = std::env::var("PROJECTION_SID").unwrap_or_else(|_| "S1".to_string());
    let resync_tx = tx.clone();
    let resync_sid = sid.clone();
    let resync_flag = resync_pending.clone();

    install_callbacks::<B>(
        &ui,
        tx.clone(),
        sid.clone(),
        next_intent_id,
        dropped_intent_count,
        outbound_queue_cap,
    );

    let writer_handle = thread::spawn(move || writer_loop(rx));

    tx.send(ready_envelope(sid))
        .map_err(|_| "failed to queue ready envelope")?;

    let reader_handle = thread::spawn(move || {
        let shared_state = ui_model_state.clone();
        let read_result = reader_loop(|envelope| match envelope {
            ElixirEnvelope::Render { sid, rev, vm } => {
                let state_for_render = shared_state.clone();
                let tx_for_resync = resync_tx.clone();
                let sid_for_resync = resync_sid.clone();
                let resync_pending_for_render = resync_flag.clone();

                let _ = ui_weak.upgrade_in_event_loop(move |ui| {
                    let Ok(mut state) = state_for_render.lock() else {
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            "failed to lock UI model state for render",
                            &resync_pending_for_render,
                            outbound_queue_cap,
                        );
                        return;
                    };

                    if sid != sid_for_resync {
                        reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            "sid mismatch for render envelope",
                            &resync_pending_for_render,
                            outbound_queue_cap,
                        );
                        return;
                    }

                    if let Err(err) = validate_render_rev(&state, rev) {
                        reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            &format!("invalid render revision: {err}"),
                            &resync_pending_for_render,
                            outbound_queue_cap,
                        );
                        return;
                    }

                    if let Err(err) = apply_render::<B>(&ui, &vm, &mut state) {
                        let screen = vm.pointer("/screen/name")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown");
                        show_error_screen::<B>(
                            &ui,
                            "Render Error",
                            &err,
                            screen,
                        );
                        reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            &format!("render apply failed: {err}"),
                            &resync_pending_for_render,
                            outbound_queue_cap,
                        );
                        return;
                    }

                    mark_applied_rev(&mut state, rev);
                    resync_pending_for_render.store(false, Ordering::Release);
                });
            }
            ElixirEnvelope::Patch { sid, rev, ack, ops } => {
                let state_for_patch = shared_state.clone();
                let tx_for_resync = resync_tx.clone();
                let sid_for_resync = resync_sid.clone();
                let resync_pending_for_patch = resync_flag.clone();

                let _ = ui_weak.upgrade_in_event_loop(move |ui| {
                    let Ok(mut state) = state_for_patch.lock() else {
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            "failed to lock UI model state for patch",
                            &resync_pending_for_patch,
                            outbound_queue_cap,
                        );
                        return;
                    };

                    if sid != sid_for_resync {
                        reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            "sid mismatch for patch envelope",
                            &resync_pending_for_patch,
                            outbound_queue_cap,
                        );
                        return;
                    }

                    if let Err(err) = validate_patch_rev(&state, rev) {
                        reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            &format!("invalid patch revision: {err}"),
                            &resync_pending_for_patch,
                            outbound_queue_cap,
                        );
                        return;
                    }

                    if let Err(err) = apply_patch::<B>(&ui, &ops, &mut state) {
                        let screen = state.vm.pointer("/screen/name")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown");
                        show_error_screen::<B>(
                            &ui,
                            "Patch Error",
                            &err,
                            screen,
                        );
                        reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            &format!("patch apply failed: {err}"),
                            &resync_pending_for_patch,
                            outbound_queue_cap,
                        );
                        return;
                    }

                    mark_applied_rev(&mut state, rev);
                    mark_applied_ack(&mut state, ack);
                });
            }
            ElixirEnvelope::Error {
                sid,
                rev,
                code,
                message,
            } => {
                eprintln!("server error sid={sid} rev={rev:?}: {code}: {message}");
                if should_resync_for_error(&code) {
                    request_resync(
                        &resync_tx,
                        &resync_sid,
                        &format!("server requested resync via error code '{code}'"),
                        &resync_flag,
                        outbound_queue_cap,
                    );
                }
            }
        });

        if let Err(err) = &read_result {
            eprintln!("reader loop terminated with error: {err}");
        }

        let quit_result = slint::invoke_from_event_loop(|| {
            let _ = slint::quit_event_loop();
        });

        if let Err(err) = quit_result {
            eprintln!("failed to request UI event loop quit: {err}");
        }

        read_result
    });

    ui.run()?;

    // Drop UI first so callback closures release their `tx` clones.
    drop(ui);
    drop(tx);

    if reader_handle.is_finished() {
        match reader_handle.join() {
            Ok(Ok(())) => {}
            Ok(Err(err)) => eprintln!("reader thread returned error: {err}"),
            Err(err) => eprintln!("reader thread join failed: {err:?}"),
        }
    } else {
        // Avoid hanging process exit on a blocked stdio read during teardown.
        eprintln!("reader thread still active during shutdown; skipping join");
    }

    if writer_handle.is_finished() {
        match writer_handle.join() {
            Ok(Ok(())) => {}
            Ok(Err(err)) => eprintln!("writer thread returned error: {err}"),
            Err(err) => eprintln!("writer thread join failed: {err:?}"),
        }
    } else {
        // Avoid hanging process exit on a blocked stdio write during teardown.
        eprintln!("writer thread still active during shutdown; skipping join");
    }

    Ok(())
}

fn install_callbacks<B: HostBindings>(
    ui: &B::Ui,
    tx: SyncSender<UiEnvelope>,
    sid: String,
    next_intent_id: Arc<AtomicU64>,
    dropped_intent_count: Arc<AtomicU64>,
    queue_capacity: usize,
) {
    let bridge_tx = tx.clone();
    let bridge_sid = sid.clone();
    let bridge_next_id = next_intent_id.clone();
    let bridge_drop_count = dropped_intent_count.clone();
    B::bind_bridge_intent(ui, move |intent_name, intent_arg| {
        if intent_name.is_empty() {
            return;
        }

        let payload = if intent_arg.is_empty() {
            json!({})
        } else {
            json!({ "arg": intent_arg })
        };

        send_intent(
            &bridge_tx,
            bridge_sid.clone(),
            &bridge_next_id,
            &intent_name,
            payload,
            &bridge_drop_count,
            queue_capacity,
        );
    });

    let intent_tx = tx.clone();
    let intent_sid = sid.clone();
    let intent_next_id = next_intent_id.clone();
    let intent_drop_count = dropped_intent_count.clone();
    B::bind_ui_intent(ui, move |intent_name, intent_arg| {
        if intent_name.is_empty() {
            return;
        }

        let payload = if intent_arg.is_empty() {
            json!({})
        } else {
            json!({ "arg": intent_arg })
        };

        send_intent(
            &intent_tx,
            intent_sid.clone(),
            &intent_next_id,
            &intent_name,
            payload,
            &intent_drop_count,
            queue_capacity,
        );
    });

    let navigate_tx = tx.clone();
    let navigate_sid = sid.clone();
    let navigate_intent_id = next_intent_id.clone();
    let navigate_drop_count = dropped_intent_count.clone();
    B::bind_navigate(ui, move |route_name, params_json| {
        if route_name.is_empty() {
            return;
        }

        let params = parse_params_json(&params_json);
        let payload = json!({ "to": route_name, "params": params });

        send_intent(
            &navigate_tx,
            navigate_sid.clone(),
            &navigate_intent_id,
            "ui.route.navigate",
            payload,
            &navigate_drop_count,
            queue_capacity,
        );
    });
}

fn send_intent(
    tx: &SyncSender<UiEnvelope>,
    sid: String,
    next_intent_id: &AtomicU64,
    name: &str,
    payload: serde_json::Value,
    dropped_intent_count: &AtomicU64,
    queue_capacity: usize,
) {
    let id = next_intent_id.fetch_add(1, Ordering::Relaxed);
    let envelope = intent_envelope(sid, id, name.to_string(), payload);

    match tx.try_send(envelope) {
        Ok(()) => {}
        Err(TrySendError::Full(_envelope)) => {
            let dropped = dropped_intent_count.fetch_add(1, Ordering::Relaxed) + 1;
            if dropped == 1 || dropped.is_power_of_two() {
                eprintln!(
                    "ui intent queue full (cap={queue_capacity}); dropped {dropped} intent(s)"
                );
            }
        }
        Err(TrySendError::Disconnected(_envelope)) => {
            eprintln!("failed to queue UI intent: {name}");
        }
    }
}

fn request_resync(
    tx: &SyncSender<UiEnvelope>,
    sid: &str,
    reason: &str,
    resync_pending: &AtomicBool,
    queue_capacity: usize,
) {
    if resync_pending
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return;
    }

    eprintln!("{reason}; requesting resync");

    enqueue_control_envelope(
        tx.clone(),
        ready_envelope_with_reason(sid.to_string(), Some(reason.to_string())),
        queue_capacity,
    );
}

fn show_error_screen<B: HostBindings>(ui: &B::Ui, title: &str, message: &str, screen_module: &str) {
    B::set_active_screen(ui, "error");
    B::set_error_title(ui, title);
    B::set_error_message(ui, message);
    B::set_error_screen_module(ui, screen_module);
}

fn apply_render<B: HostBindings>(
    ui: &B::Ui,
    vm: &Value,
    ui_model_state: &mut UiModelState<B::ScreenId>,
) -> Result<(), String> {
    ui_model_state.vm = vm.clone();
    apply_global_props::<B>(ui, &ui_model_state.vm);
    B::apply_app_render(ui, &ui_model_state.vm)?;
    let screen_id = B::apply_screen_render(ui, vm)?;
    ui_model_state.screen_id = screen_id;
    Ok(())
}

fn apply_patch<B: HostBindings>(
    ui: &B::Ui,
    ops: &[PatchOp],
    ui_model_state: &mut UiModelState<B::ScreenId>,
) -> Result<(), String> {
    apply_vm_patch_ops(&mut ui_model_state.vm, ops)?;
    apply_global_props::<B>(ui, &ui_model_state.vm);
    B::apply_app_patch(ui, ops, &ui_model_state.vm)?;

    if patch_changes_screen::<B>(ops) {
        let screen_id = B::apply_screen_render(ui, &ui_model_state.vm)?;
        ui_model_state.screen_id = screen_id;
        Ok(())
    } else {
        B::apply_screen_patch(ui, ui_model_state.screen_id, ops, &ui_model_state.vm)
    }
}

fn apply_global_props<B: HostBindings>(ui: &B::Ui, vm: &Value) {
    let app_title = vm
        .pointer("/app/title")
        .and_then(Value::as_str)
        .unwrap_or("Projection");
    B::set_app_title(ui, app_title);

    let active_screen = vm
        .pointer("/screen/name")
        .and_then(Value::as_str)
        .unwrap_or("error");
    B::set_active_screen(ui, active_screen);

    let nav_can_back = vm
        .pointer("/nav/stack")
        .and_then(Value::as_array)
        .map(|stack| stack.len() > 1)
        .unwrap_or(false);
    B::set_nav_can_back(ui, nav_can_back);

    let error_title = vm
        .pointer("/screen/vm/title")
        .and_then(Value::as_str)
        .unwrap_or("");
    B::set_error_title(ui, error_title);

    let error_message = vm
        .pointer("/screen/vm/message")
        .and_then(Value::as_str)
        .unwrap_or("");
    B::set_error_message(ui, error_message);

    let error_screen_module = vm
        .pointer("/screen/vm/screen_module")
        .and_then(Value::as_str)
        .unwrap_or("");
    B::set_error_screen_module(ui, error_screen_module);
}

fn patch_changes_screen<B: HostBindings>(ops: &[PatchOp]) -> bool {
    ops.iter().any(|op| match op {
        PatchOp::Replace { path, .. } | PatchOp::Add { path, .. } | PatchOp::Remove { path } => {
            B::patch_changes_screen(path)
        }
    })
}

pub fn validate_render_rev<ScreenId: Copy + Default>(
    state: &UiModelState<ScreenId>,
    rev: u64,
) -> Result<(), String> {
    match state.last_rev {
        Some(last_rev) if rev == last_rev.wrapping_add(1) => Ok(()),
        Some(last_rev) => Err(format!(
            "render revision mismatch: rev={rev}, expected={}",
            last_rev.wrapping_add(1)
        )),
        None => Ok(()),
    }
}

pub fn validate_patch_rev<ScreenId: Copy + Default>(
    state: &UiModelState<ScreenId>,
    rev: u64,
) -> Result<(), String> {
    match state.last_rev {
        Some(last_rev) if rev == last_rev.wrapping_add(1) => Ok(()),
        Some(last_rev) => Err(format!(
            "patch revision mismatch: rev={rev}, expected={}",
            last_rev.wrapping_add(1)
        )),
        None => Err(format!(
            "patch received before initial render: rev={rev}, expected initial render"
        )),
    }
}

pub fn mark_applied_rev<ScreenId: Copy + Default>(state: &mut UiModelState<ScreenId>, rev: u64) {
    state.last_rev = Some(rev);
}

pub fn mark_applied_ack<ScreenId: Copy + Default>(
    state: &mut UiModelState<ScreenId>,
    ack: Option<u64>,
) {
    match (state.last_ack, ack) {
        (_current, None) => {}
        (None, Some(next_ack)) => state.last_ack = Some(next_ack),
        (Some(current_ack), Some(next_ack)) => state.last_ack = Some(current_ack.max(next_ack)),
    }
}

pub fn reset_for_resync<ScreenId: Copy + Default>(state: &mut UiModelState<ScreenId>) {
    *state = UiModelState::default();
}

fn parse_params_json(raw: &str) -> Value {
    if raw.is_empty() {
        return json!({});
    }

    match serde_json::from_str::<Value>(raw) {
        Ok(Value::Object(map)) => Value::Object(map),
        Ok(_) => json!({}),
        Err(_) => json!({}),
    }
}

fn enqueue_control_envelope(
    tx: SyncSender<UiEnvelope>,
    envelope: UiEnvelope,
    queue_capacity: usize,
) {
    match tx.try_send(envelope) {
        Ok(()) => {}
        Err(TrySendError::Full(envelope)) => {
            eprintln!(
                "ui outbound queue full (cap={queue_capacity}); waiting to enqueue control envelope"
            );
            thread::spawn(move || {
                if tx.send(envelope).is_err() {
                    eprintln!("failed to enqueue control envelope");
                }
            });
        }
        Err(TrySendError::Disconnected(_envelope)) => {
            eprintln!("failed to enqueue control envelope");
        }
    }
}

fn should_resync_for_error(code: &str) -> bool {
    matches!(
        code,
        "decode_error"
            | "frame_too_large"
            | "invalid_envelope"
            | "resync_required"
            | "rev_mismatch"
            | "patch_apply_error"
    )
}

fn parse_outbound_queue_capacity() -> usize {
    std::env::var("PROJECTION_UI_OUTBOUND_QUEUE_CAP")
        .ok()
        .and_then(|raw| raw.parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_UI_OUTBOUND_QUEUE_CAP)
}

fn apply_vm_patch_ops(vm: &mut Value, ops: &[PatchOp]) -> Result<(), String> {
    for op in ops {
        match op {
            PatchOp::Replace { path, value } => set_path(vm, path, value.clone(), true)?,
            PatchOp::Add { path, value } => set_path(vm, path, value.clone(), false)?,
            PatchOp::Remove { path } => remove_path(vm, path)?,
        }
    }

    Ok(())
}

fn set_path(root: &mut Value, path: &str, value: Value, replace_only: bool) -> Result<(), String> {
    let tokens = parse_pointer(path)?;

    if tokens.is_empty() {
        *root = value;
        return Ok(());
    }

    let mut current = root;

    for token in &tokens[..tokens.len() - 1] {
        current = descend_or_create(current, token)?;
    }

    let last = tokens.last().expect("tokens not empty");

    match current {
        Value::Object(map) => {
            if replace_only && !map.contains_key(last) {
                return Err(format!("replace path does not exist: {path}"));
            }

            map.insert(last.clone(), value);
            Ok(())
        }
        Value::Array(items) => {
            let index = parse_index(last, items.len(), path)?;

            if index == items.len() {
                items.push(value);
            } else {
                items[index] = value;
            }

            Ok(())
        }
        _ => Err(format!("cannot set path on non-container parent: {path}")),
    }
}

fn remove_path(root: &mut Value, path: &str) -> Result<(), String> {
    let tokens = parse_pointer(path)?;

    if tokens.is_empty() {
        *root = Value::Object(serde_json::Map::new());
        return Ok(());
    }

    let mut current = root;

    for token in &tokens[..tokens.len() - 1] {
        current = descend_existing(current, token)
            .ok_or_else(|| format!("remove path does not exist: {path}"))?;
    }

    let last = tokens.last().expect("tokens not empty");

    match current {
        Value::Object(map) => {
            if map.remove(last).is_some() {
                Ok(())
            } else {
                Err(format!("remove path does not exist: {path}"))
            }
        }
        Value::Array(items) => {
            let index = parse_index(last, items.len().saturating_sub(1), path)?;

            if index < items.len() {
                items.remove(index);
                Ok(())
            } else {
                Err(format!("remove path index out of bounds: {path}"))
            }
        }
        _ => Err(format!(
            "cannot remove path on non-container parent: {path}"
        )),
    }
}

fn parse_pointer(path: &str) -> Result<Vec<String>, String> {
    if path.is_empty() {
        return Ok(vec![]);
    }

    if !path.starts_with('/') {
        return Err(format!("invalid json pointer path: {path}"));
    }

    path.split('/')
        .skip(1)
        .map(unescape_json_pointer_token)
        .collect()
}

fn unescape_json_pointer_token(token: &str) -> Result<String, String> {
    let mut out = String::with_capacity(token.len());
    let mut chars = token.chars();

    while let Some(ch) = chars.next() {
        if ch == '~' {
            match chars.next() {
                Some('0') => out.push('~'),
                Some('1') => out.push('/'),
                Some(other) => {
                    return Err(format!("invalid escape ~{other} in json pointer token"));
                }
                None => return Err("trailing ~ in json pointer token".to_string()),
            }
        } else {
            out.push(ch);
        }
    }

    Ok(out)
}

fn descend_or_create<'a>(value: &'a mut Value, token: &str) -> Result<&'a mut Value, String> {
    match value {
        Value::Object(map) => Ok(map
            .entry(token.to_string())
            .or_insert_with(|| Value::Object(serde_json::Map::new()))),
        Value::Array(items) => {
            let index = parse_index(token, items.len(), token)?;
            items
                .get_mut(index)
                .ok_or_else(|| format!("array index out of bounds at token {token}"))
        }
        _ => Err(format!(
            "cannot descend into non-container value at token {token}"
        )),
    }
}

fn descend_existing<'a>(value: &'a mut Value, token: &str) -> Option<&'a mut Value> {
    match value {
        Value::Object(map) => map.get_mut(token),
        Value::Array(items) => token
            .parse::<usize>()
            .ok()
            .and_then(|index| items.get_mut(index)),
        _ => None,
    }
}

fn parse_index(token: &str, max_len: usize, path: &str) -> Result<usize, String> {
    let index = token
        .parse::<usize>()
        .map_err(|_| format!("invalid array index '{token}' at path {path}"))?;

    if index > max_len {
        Err(format!(
            "array index out of bounds '{token}' at path {path}"
        ))
    } else {
        Ok(index)
    }
}

#[macro_export]
macro_rules! app_main {
    ($window:ty, $ui_global:ty, $error_global:ty, $generated:ident) => {
        struct ProjectionRuntimeBindings;

        impl $crate::HostBindings for ProjectionRuntimeBindings {
            type Ui = $window;
            type ScreenId = $generated::ScreenId;

            fn new_ui() -> Result<Self::Ui, slint::PlatformError> {
                <Self::Ui>::new()
            }

            fn bind_bridge_intent<F>(ui: &Self::Ui, handler: F)
            where
                F: Fn(String, String) + Send + 'static,
            {
                let bridge = ui.global::<$ui_global>();
                bridge.on_intent(move |intent_name, intent_arg| {
                    handler(intent_name.to_string(), intent_arg.to_string());
                });
            }

            fn bind_ui_intent<F>(ui: &Self::Ui, handler: F)
            where
                F: Fn(String, String) + Send + 'static,
            {
                ui.on_ui_intent(move |intent_name, intent_arg| {
                    handler(intent_name.to_string(), intent_arg.to_string());
                });
            }

            fn bind_navigate<F>(ui: &Self::Ui, handler: F)
            where
                F: Fn(String, String) + Send + 'static,
            {
                ui.on_navigate(move |route_name, params_json| {
                    handler(route_name.to_string(), params_json.to_string());
                });
            }

            fn set_app_title(ui: &Self::Ui, title: &str) {
                ui.set_app_title(title.into());
            }

            fn set_active_screen(ui: &Self::Ui, active_screen: &str) {
                ui.set_active_screen(active_screen.into());
            }

            fn set_nav_can_back(ui: &Self::Ui, nav_can_back: bool) {
                ui.set_nav_can_back(nav_can_back);
            }

            fn set_error_title(ui: &Self::Ui, title: &str) {
                let error_state = ui.global::<$error_global>();
                error_state.set_error_title(title.into());
            }

            fn set_error_message(ui: &Self::Ui, message: &str) {
                let error_state = ui.global::<$error_global>();
                error_state.set_error_message(message.into());
            }

            fn set_error_screen_module(ui: &Self::Ui, screen_module: &str) {
                let error_state = ui.global::<$error_global>();
                error_state.set_error_screen_module(screen_module.into());
            }

            fn apply_screen_render(
                ui: &Self::Ui,
                vm: &$crate::serde_json::Value,
            ) -> Result<Self::ScreenId, String> {
                $generated::apply_render(ui, vm)
            }

            fn apply_screen_patch(
                ui: &Self::Ui,
                screen_id: Self::ScreenId,
                ops: &[$crate::PatchOp],
                vm: &$crate::serde_json::Value,
            ) -> Result<(), String> {
                $generated::apply_patch(ui, screen_id, ops, vm)
            }

            fn apply_app_render(
                ui: &Self::Ui,
                vm: &$crate::serde_json::Value,
            ) -> Result<(), String> {
                $generated::apply_app_render(ui, vm)
            }

            fn apply_app_patch(
                ui: &Self::Ui,
                ops: &[$crate::PatchOp],
                vm: &$crate::serde_json::Value,
            ) -> Result<(), String> {
                $generated::apply_app_patch(ui, ops, vm)
            }
        }

        fn main() {
            if let Err(err) = $crate::run::<ProjectionRuntimeBindings>() {
                eprintln!("ui_host fatal error: {err}");
                std::process::exit(1);
            }
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn send_intent_drops_when_queue_is_full() {
        let (tx, rx) = mpsc::sync_channel(1);
        let next_intent_id = AtomicU64::new(1);
        let dropped = AtomicU64::new(0);

        tx.send(ready_envelope("S1".to_string()))
            .expect("seed queue with one envelope");

        send_intent(
            &tx,
            "S1".to_string(),
            &next_intent_id,
            "clock.pause",
            json!({}),
            &dropped,
            1,
        );

        assert_eq!(dropped.load(Ordering::Relaxed), 1);

        let seeded = rx.try_recv().expect("seed envelope remains queued");
        match seeded {
            UiEnvelope::Ready { sid, .. } => assert_eq!(sid, "S1"),
            other => panic!("expected ready envelope, got {other:?}"),
        }
    }

    #[test]
    fn resync_error_codes_are_explicit() {
        assert!(should_resync_for_error("decode_error"));
        assert!(should_resync_for_error("frame_too_large"));
        assert!(should_resync_for_error("invalid_envelope"));
        assert!(should_resync_for_error("resync_required"));
        assert!(!should_resync_for_error("validation_warning"));
    }

    #[test]
    fn render_rev_accepts_first_and_next_revision() {
        let mut state = UiModelState::<u8>::default();
        assert!(validate_render_rev(&state, 1).is_ok());
        mark_applied_rev(&mut state, 1);
        assert!(validate_render_rev(&state, 2).is_ok());
    }

    #[test]
    fn render_rev_rejects_stale_or_skipped_revisions() {
        let mut state = UiModelState::<u8>::default();
        mark_applied_rev(&mut state, 5);
        assert!(validate_render_rev(&state, 5).is_err());
        assert!(validate_render_rev(&state, 4).is_err());
        assert!(validate_render_rev(&state, 7).is_err());
    }

    #[test]
    fn patch_rev_requires_next_monotonic_revision() {
        let mut state = UiModelState::<u8>::default();
        assert!(validate_patch_rev(&state, 1).is_err());
        mark_applied_rev(&mut state, 3);
        assert!(validate_patch_rev(&state, 4).is_ok());
        assert!(validate_patch_rev(&state, 5).is_err());
    }

    #[test]
    fn ack_tracking_uses_monotonic_high_watermark() {
        let mut state = UiModelState::<u8>::default();
        mark_applied_ack(&mut state, None);
        assert_eq!(state.last_ack, None);

        mark_applied_ack(&mut state, Some(5));
        assert_eq!(state.last_ack, Some(5));

        mark_applied_ack(&mut state, Some(3));
        assert_eq!(state.last_ack, Some(5));

        mark_applied_ack(&mut state, Some(8));
        assert_eq!(state.last_ack, Some(8));
    }
}
