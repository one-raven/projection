//! Build-time scanner for Projection hooks.
//!
//! Call from `build.rs`:
//!
//! ```ignore
//! projection_ui_host_codegen::scan_and_emit(
//!     std::path::Path::new("src/hooks/mod.rs"),
//!     std::path::Path::new("src/generated/app.slint"),
//!     std::path::Path::new("src/generated_hooks"),
//! )?;
//! ```
//!
//! v1 scope:
//! - Scans a single file (`src/hooks/mod.rs`). Hooks must be top-level `pub fn` items there.
//! - Only async hooks supported (`#[hook]`). `#[hook(sync)]` is reserved and will error.
//! - Supported types: `SharedString` (string), `i32`/`i64` (int), `f32`/`f64` (float),
//!   `bool` (bool), `slint::Image` / `Image` (image).
//! - Each hook gets a Slint global `<PascalName>Hook` with outputs `result`, `loading`, `error`
//!   and an `invoke(...)` callback the user triggers from Slint.
//! - Emits `hooks.slint`, `root.slint`, `register.rs` under the provided output directory.

use std::fs;
use std::path::{Path, PathBuf};
use syn::{FnArg, GenericArgument, Item, ItemFn, Pat, PathArguments, ReturnType, Type, Visibility};

#[derive(Debug, Clone)]
pub struct Hook {
    pub fn_name: String,
    pub global_name: String,
    pub inputs: Vec<HookInput>,
    pub output: SlintType,
    /// Rust expression that converts the hook's return value (named
    /// `value`) into the type needed to set the Slint property. For
    /// direct `slint::Image` returns this is just `value`; for
    /// `SharedPixelBuffer<Rgba8Pixel>` returns it wraps the buffer
    /// with `from_rgba8_premultiplied` so the conversion happens on
    /// the UI thread (the buffer is Send; slint::Image is not).
    pub output_setter_expr: String,
    pub mode: HookMode,
}

#[derive(Debug, Clone)]
pub struct HookInput {
    pub name: String,
    pub ty: SlintType,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookMode {
    Async,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlintType {
    String,
    Int,
    Float,
    Bool,
    Image,
}

impl SlintType {
    fn slint_name(self) -> &'static str {
        match self {
            Self::String => "string",
            Self::Int => "int",
            Self::Float => "float",
            Self::Bool => "bool",
            Self::Image => "image",
        }
    }

    fn slint_default(self) -> Option<&'static str> {
        match self {
            Self::String => Some("\"\""),
            Self::Int => Some("0"),
            Self::Float => Some("0.0"),
            Self::Bool => Some("false"),
            Self::Image => None,
        }
    }
}

#[derive(Debug)]
pub struct EmitOutput {
    pub hook_count: usize,
    pub scanned_files: Vec<PathBuf>,
}

pub fn scan_and_emit(
    hooks_entry: &Path,
    app_slint: &Path,
    out_dir: &Path,
) -> Result<EmitOutput, String> {
    fs::create_dir_all(out_dir)
        .map_err(|e| format!("failed to create out dir {}: {e}", out_dir.display()))?;

    let mut scanned_files = Vec::new();
    let hooks = if hooks_entry.exists() {
        scanned_files.push(hooks_entry.to_path_buf());
        scan_file(hooks_entry)?
    } else {
        Vec::new()
    };

    check_duplicate_names(&hooks)?;

    let slint_src = emit_hooks_slint(&hooks);
    write_if_changed(&out_dir.join("hooks.slint"), &slint_src)?;

    let root_src = emit_root_slint(app_slint, out_dir, &hooks);
    write_if_changed(&out_dir.join("root.slint"), &root_src)?;

    let register_src = emit_register_rs(&hooks);
    write_if_changed(&out_dir.join("register.rs"), &register_src)?;

    Ok(EmitOutput {
        hook_count: hooks.len(),
        scanned_files,
    })
}

fn write_if_changed(path: &Path, contents: &str) -> Result<(), String> {
    if let Ok(existing) = fs::read_to_string(path) {
        if existing == contents {
            return Ok(());
        }
    }
    fs::write(path, contents).map_err(|e| format!("failed to write {}: {e}", path.display()))
}

fn scan_file(path: &Path) -> Result<Vec<Hook>, String> {
    let source = fs::read_to_string(path)
        .map_err(|e| format!("failed to read {}: {e}", path.display()))?;
    let file = syn::parse_file(&source)
        .map_err(|e| format!("failed to parse {}: {e}", path.display()))?;

    let mut hooks = Vec::new();
    for item in &file.items {
        let Item::Fn(func) = item else {
            continue;
        };
        let Some(mode) = find_hook_mode(func, path)? else {
            continue;
        };
        hooks.push(extract_hook(func, mode, path)?);
    }
    Ok(hooks)
}

fn find_hook_mode(func: &ItemFn, path: &Path) -> Result<Option<HookMode>, String> {
    let mut found = None;
    for attr in &func.attrs {
        let last = attr.path().segments.last().map(|s| s.ident.to_string());
        if last.as_deref() != Some("hook") {
            continue;
        }
        if found.is_some() {
            return Err(format!(
                "{}: function `{}` has multiple #[hook] attributes",
                path.display(),
                func.sig.ident
            ));
        }
        let tokens = attr.meta.require_list().ok().map(|l| l.tokens.to_string());
        let arg = tokens.as_deref().unwrap_or("").trim().to_string();
        let mode = match arg.as_str() {
            "" | "async" => HookMode::Async,
            "sync" => {
                return Err(format!(
                    "{}: `{}` uses #[hook(sync)] but sync hooks are not yet implemented",
                    path.display(),
                    func.sig.ident
                ));
            }
            other => {
                return Err(format!(
                    "{}: `{}` has unknown #[hook({})] argument",
                    path.display(),
                    func.sig.ident,
                    other
                ));
            }
        };
        found = Some(mode);
    }
    Ok(found)
}

fn extract_hook(func: &ItemFn, mode: HookMode, path: &Path) -> Result<Hook, String> {
    if !matches!(func.vis, Visibility::Public(_)) {
        return Err(format!(
            "{}: hook `{}` must be `pub fn`",
            path.display(),
            func.sig.ident
        ));
    }
    if func.sig.asyncness.is_some() {
        return Err(format!(
            "{}: hook `{}` must not be `async fn` (the framework handles threading)",
            path.display(),
            func.sig.ident
        ));
    }
    if !func.sig.generics.params.is_empty() {
        return Err(format!(
            "{}: hook `{}` must not be generic",
            path.display(),
            func.sig.ident
        ));
    }

    let mut inputs = Vec::new();
    for arg in &func.sig.inputs {
        let FnArg::Typed(pat_ty) = arg else {
            return Err(format!(
                "{}: hook `{}` cannot take `self`",
                path.display(),
                func.sig.ident
            ));
        };
        let Pat::Ident(ident) = pat_ty.pat.as_ref() else {
            return Err(format!(
                "{}: hook `{}` arguments must be simple identifiers",
                path.display(),
                func.sig.ident
            ));
        };
        let ty = map_type(&pat_ty.ty).ok_or_else(|| {
            format!(
                "{}: hook `{}` argument `{}` has unsupported type `{}`. \
                 Supported: SharedString, i32, i64, f32, f64, bool, slint::Image",
                path.display(),
                func.sig.ident,
                ident.ident,
                quote_type(&pat_ty.ty),
            )
        })?;
        inputs.push(HookInput {
            name: ident.ident.to_string(),
            ty,
        });
    }

    let (output, output_setter_expr) = match &func.sig.output {
        ReturnType::Default => {
            return Err(format!(
                "{}: hook `{}` must return a value (use `()`-like hooks are not supported)",
                path.display(),
                func.sig.ident
            ));
        }
        ReturnType::Type(_, ty) => map_output_type(ty).ok_or_else(|| {
            format!(
                "{}: hook `{}` return type `{}` is unsupported. \
                 Supported: SharedString, i32, i64, f32, f64, bool, slint::Image, \
                 slint::SharedPixelBuffer<slint::Rgba8Pixel>",
                path.display(),
                func.sig.ident,
                quote_type(ty),
            )
        })?,
    };

    let fn_name = func.sig.ident.to_string();
    let global_name = format!("{}Hook", pascal_case(&fn_name));

    Ok(Hook {
        fn_name,
        global_name,
        inputs,
        output,
        output_setter_expr,
        mode,
    })
}

/// Map a Rust return type to `(SlintType, setter_expr)`. `setter_expr`
/// is the Rust expression — with the hook's return value bound to
/// `value` — that yields the type the Slint property expects.
fn map_output_type(ty: &Type) -> Option<(SlintType, String)> {
    if let Some(slint_ty) = map_type(ty) {
        return Some((slint_ty, "value".to_string()));
    }

    // SharedPixelBuffer<Rgba8Pixel> → Slint `image`. Unlike slint::Image,
    // the buffer is Send, so it can cross from the worker thread; we
    // build the Image on the UI thread before setting the property.
    let Type::Path(type_path) = ty else { return None; };
    let last = type_path.path.segments.last()?;
    if last.ident != "SharedPixelBuffer" {
        return None;
    }
    let PathArguments::AngleBracketed(args) = &last.arguments else { return None; };
    let inner = args.args.first()?;
    let GenericArgument::Type(inner_ty) = inner else { return None; };
    let Type::Path(inner_path) = inner_ty else { return None; };
    let inner_last = inner_path.path.segments.last()?;
    if inner_last.ident != "Rgba8Pixel" {
        return None;
    }
    Some((
        SlintType::Image,
        "slint::Image::from_rgba8_premultiplied(value)".to_string(),
    ))
}

fn map_type(ty: &Type) -> Option<SlintType> {
    let Type::Path(type_path) = ty else {
        return None;
    };
    let last = type_path.path.segments.last()?;
    // Reject types with generic args (e.g. Option<T>) except the inner image handling below.
    if !matches!(last.arguments, PathArguments::None) {
        return None;
    }
    let name = last.ident.to_string();
    match name.as_str() {
        "SharedString" | "String" => Some(SlintType::String),
        "i32" | "i64" | "isize" | "u32" => Some(SlintType::Int),
        "f32" | "f64" => Some(SlintType::Float),
        "bool" => Some(SlintType::Bool),
        "Image" => Some(SlintType::Image),
        _ => None,
    }
}

fn quote_type(ty: &Type) -> String {
    // Minimal stringification: good enough for error messages.
    match ty {
        Type::Path(p) => {
            let segments: Vec<String> = p
                .path
                .segments
                .iter()
                .map(|s| {
                    let base = s.ident.to_string();
                    match &s.arguments {
                        PathArguments::None => base,
                        PathArguments::AngleBracketed(args) => {
                            let inner: Vec<String> = args
                                .args
                                .iter()
                                .map(|a| match a {
                                    GenericArgument::Type(t) => quote_type(t),
                                    _ => "?".into(),
                                })
                                .collect();
                            format!("{base}<{}>", inner.join(", "))
                        }
                        PathArguments::Parenthesized(_) => format!("{base}(...)"),
                    }
                })
                .collect();
            segments.join("::")
        }
        Type::Reference(r) => format!("&{}", quote_type(&r.elem)),
        _ => "<unsupported>".into(),
    }
}

fn check_duplicate_names(hooks: &[Hook]) -> Result<(), String> {
    let mut seen = std::collections::HashSet::new();
    for h in hooks {
        if !seen.insert(h.fn_name.clone()) {
            return Err(format!(
                "duplicate hook name `{}` — each hook must have a unique fn name",
                h.fn_name
            ));
        }
    }
    Ok(())
}

fn pascal_case(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut upper = true;
    for ch in s.chars() {
        if ch == '_' {
            upper = true;
            continue;
        }
        if upper {
            for u in ch.to_uppercase() {
                out.push(u);
            }
            upper = false;
        } else {
            out.push(ch);
        }
    }
    out
}

fn emit_hooks_slint(hooks: &[Hook]) -> String {
    let mut out = String::new();
    out.push_str("// generated by projection_ui_host_codegen; do not edit manually\n");
    out.push_str("// Hooks: pure Rust functions invoked from Slint on a background thread.\n\n");

    if hooks.is_empty() {
        out.push_str("// No hooks discovered. Add #[hook] functions in src/hooks/mod.rs.\n");
        // Slint requires at least one definition in a file we import; export a placeholder.
        out.push_str("export global __ProjectionHooksStub {\n    in property <int> __stub;\n}\n");
        return out;
    }

    for hook in hooks {
        out.push_str(&format!("export global {} {{\n", hook.global_name));
        // Hook output/status is written from Rust and read from Slint. `in property`
        // is what Slint calls that direction — from Rust's perspective it looks like
        // a push into the UI, which matches how Rust marshals results back.
        let default = hook.output.slint_default();
        let output_line = match default {
            Some(d) => format!("    in property <{}> result: {};\n", hook.output.slint_name(), d),
            None => format!("    in property <{}> result;\n", hook.output.slint_name()),
        };
        out.push_str(&output_line);
        out.push_str("    in property <bool> loading: false;\n");
        out.push_str("    in property <string> error: \"\";\n");
        let params: Vec<String> = hook
            .inputs
            .iter()
            .map(|i| format!("{}: {}", i.name, i.ty.slint_name()))
            .collect();
        out.push_str(&format!("    callback invoke({});\n", params.join(", ")));
        out.push_str("}\n\n");
    }

    out
}

fn emit_root_slint(app_slint: &Path, out_dir: &Path, hooks: &[Hook]) -> String {
    // The generated root re-exports everything from the existing app.slint plus our hook globals,
    // so `slint::include_modules!()` sees all types from a single compiled entry point.
    let rel_app = relative_path(out_dir, app_slint)
        .unwrap_or_else(|| app_slint.to_string_lossy().into_owned());

    let mut app_exports = parse_slint_exports(app_slint).unwrap_or_default();
    // AppWindow is declared via `export component AppWindow ...` and should always be forwarded.
    if !app_exports.iter().any(|n| n == "AppWindow") {
        app_exports.push("AppWindow".to_string());
    }

    let mut out = String::new();
    out.push_str("// generated by projection_ui_host_codegen; do not edit manually\n");
    out.push_str(&format!(
        "import {{ {} }} from \"{rel_app}\";\n",
        app_exports.join(", ")
    ));
    if hooks.is_empty() {
        out.push_str("import { __ProjectionHooksStub } from \"hooks.slint\";\n");
    } else {
        let names: Vec<String> = hooks.iter().map(|h| h.global_name.clone()).collect();
        out.push_str(&format!(
            "import {{ {} }} from \"hooks.slint\";\n",
            names.join(", ")
        ));
    }
    out.push_str("\n");
    out.push_str(&format!("export {{ {} }}\n", app_exports.join(", ")));
    if !hooks.is_empty() {
        let names: Vec<String> = hooks.iter().map(|h| h.global_name.clone()).collect();
        out.push_str(&format!("export {{ {} }}\n", names.join(", ")));
    }
    out
}

/// Extract exported names from a Slint file.
///
/// Handles:
/// - `export { Foo, Bar }`  (bare re-export / named export block)
/// - `export { Foo } from "..."`  (re-export from file)
/// - `export component Foo inherits ...`  (component export)
/// - `export global Foo { ... }`  (global export)
///
/// This is a line-oriented scan — not a full Slint parser, but good enough for
/// the codegen'd `app.slint` which uses a simple export style.
fn parse_slint_exports(path: &Path) -> Result<Vec<String>, String> {
    let source = fs::read_to_string(path)
        .map_err(|e| format!("failed to read {}: {e}", path.display()))?;
    let mut out = Vec::new();
    for raw_line in source.lines() {
        let line = raw_line.trim();
        if line.starts_with("//") || !line.starts_with("export") {
            continue;
        }
        let rest = line.trim_start_matches("export").trim_start();
        if let Some(names) = rest.strip_prefix('{').and_then(|r| r.split('}').next()) {
            for name in names.split(',') {
                let name = name.trim();
                if !name.is_empty() {
                    push_unique(&mut out, name);
                }
            }
        } else if let Some(rest) = rest.strip_prefix("component ") {
            if let Some(name) = rest.split_whitespace().next() {
                push_unique(&mut out, name);
            }
        } else if let Some(rest) = rest.strip_prefix("global ") {
            if let Some(name) = rest.split_whitespace().next() {
                let name = name.trim_end_matches('{').trim();
                if !name.is_empty() {
                    push_unique(&mut out, name);
                }
            }
        } else if let Some(rest) = rest.strip_prefix("struct ") {
            if let Some(name) = rest.split_whitespace().next() {
                let name = name.trim_end_matches('{').trim();
                if !name.is_empty() {
                    push_unique(&mut out, name);
                }
            }
        }
    }
    Ok(out)
}

fn push_unique(vec: &mut Vec<String>, name: &str) {
    if !vec.iter().any(|n| n == name) {
        vec.push(name.to_string());
    }
}

fn emit_register_rs(hooks: &[Hook]) -> String {
    let mut out = String::new();
    out.push_str("// generated by projection_ui_host_codegen; do not edit manually\n\n");
    out.push_str("#[allow(dead_code)]\n");
    out.push_str("pub fn register_hooks(ui: &crate::AppWindow) {\n");
    for hook in hooks {
        out.push_str(&format!("    register_{}(ui);\n", hook.fn_name));
    }
    out.push_str("}\n\n");

    for hook in hooks {
        out.push_str(&emit_hook_binding(hook));
    }

    out
}

fn emit_hook_binding(hook: &Hook) -> String {
    let global = &hook.global_name;
    let fn_name = &hook.fn_name;
    let setter = &hook.output_setter_expr;

    let cb_params: Vec<String> = hook.inputs.iter().map(|i| i.name.clone()).collect();
    let cb_param_list = cb_params.join(", ");
    let call_args = cb_params.join(", ");

    format!(
        r#"#[allow(dead_code)]
fn register_{fn_name}(ui: &crate::AppWindow) {{
    use slint::ComponentHandle;
    let ui_weak = ui.as_weak();
    let counter = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    let global = ui.global::<crate::{global}>();
    let counter_cb = counter.clone();
    global.on_invoke(move |{cb_param_list}| {{
        let my_gen = counter_cb
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            .wrapping_add(1);
        if let Some(ui) = ui_weak.upgrade() {{
            let g = ui.global::<crate::{global}>();
            g.set_loading(true);
            g.set_error(slint::SharedString::new());
        }}
        let ui_weak_t = ui_weak.clone();
        let counter_t = counter_cb.clone();
        std::thread::spawn(move || {{
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {{
                crate::hooks::{fn_name}({call_args})
            }}));
            let _ = slint::invoke_from_event_loop(move || {{
                if counter_t.load(std::sync::atomic::Ordering::Relaxed) != my_gen {{
                    return;
                }}
                let Some(ui) = ui_weak_t.upgrade() else {{ return; }};
                let g = ui.global::<crate::{global}>();
                match result {{
                    Ok(value) => {{
                        g.set_result({setter});
                        g.set_error(slint::SharedString::new());
                    }}
                    Err(payload) => {{
                        let msg = projection_ui_host_runtime::hook_panic_message(payload);
                        g.set_error(msg.into());
                    }}
                }}
                g.set_loading(false);
            }});
        }});
    }});
}}

"#,
    )
}

fn relative_path(from_dir: &Path, to: &Path) -> Option<String> {
    let from = from_dir.canonicalize().ok()?;
    let to = to.canonicalize().ok()?;
    pathdiff(&from, &to).map(|p| p.to_string_lossy().into_owned())
}

fn pathdiff(from: &Path, to: &Path) -> Option<PathBuf> {
    // Compute a relative path from `from` to `to` using component-level comparison.
    let from_comps: Vec<_> = from.components().collect();
    let to_comps: Vec<_> = to.components().collect();
    let mut i = 0;
    while i < from_comps.len() && i < to_comps.len() && from_comps[i] == to_comps[i] {
        i += 1;
    }
    let mut result = PathBuf::new();
    for _ in i..from_comps.len() {
        result.push("..");
    }
    for comp in &to_comps[i..] {
        result.push(comp.as_os_str());
    }
    Some(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_tmp(name: &str, contents: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("projection_hooks_test_{name}"));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mod.rs");
        fs::write(&path, contents).unwrap();
        path
    }

    #[test]
    fn pascal_case_handles_snake_case() {
        assert_eq!(pascal_case("uppercase"), "Uppercase");
        assert_eq!(pascal_case("qr_image"), "QrImage");
        assert_eq!(pascal_case("a_b_c"), "ABC");
    }

    #[test]
    fn scan_extracts_hook_signature() {
        let path = write_tmp(
            "sig",
            r#"
            use projection_ui_host_runtime::hook;
            use slint::SharedString;
            #[hook]
            pub fn uppercase(text: SharedString) -> SharedString { text }
            "#,
        );
        let hooks = scan_file(&path).unwrap();
        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0].fn_name, "uppercase");
        assert_eq!(hooks[0].global_name, "UppercaseHook");
        assert_eq!(hooks[0].inputs.len(), 1);
        assert_eq!(hooks[0].inputs[0].name, "text");
        assert!(matches!(hooks[0].inputs[0].ty, SlintType::String));
        assert!(matches!(hooks[0].output, SlintType::String));
    }

    #[test]
    fn scan_rejects_private_hook() {
        let path = write_tmp(
            "private",
            r#"
            use projection_ui_host_runtime::hook;
            #[hook]
            fn private_hook(x: i32) -> i32 { x }
            "#,
        );
        let err = scan_file(&path).unwrap_err();
        assert!(err.contains("must be `pub fn`"), "got: {err}");
    }

    #[test]
    fn scan_rejects_sync_for_now() {
        let path = write_tmp(
            "sync",
            r#"
            use projection_ui_host_runtime::hook;
            #[hook(sync)]
            pub fn fast(x: i32) -> i32 { x }
            "#,
        );
        let err = scan_file(&path).unwrap_err();
        assert!(err.contains("sync hooks are not yet implemented"), "got: {err}");
    }

    #[test]
    fn scan_skips_unannotated_fns() {
        let path = write_tmp(
            "skip",
            r#"
            pub fn plain(x: i32) -> i32 { x }
            "#,
        );
        let hooks = scan_file(&path).unwrap();
        assert!(hooks.is_empty());
    }

    #[test]
    fn emit_hooks_slint_handles_empty_set() {
        let s = emit_hooks_slint(&[]);
        assert!(s.contains("__ProjectionHooksStub"));
    }

    #[test]
    fn parse_slint_exports_picks_up_named_and_component_exports() {
        let dir = std::env::temp_dir().join("projection_hooks_test_exports");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("app.slint");
        fs::write(
            &path,
            r#"
            export { UI } from "ui.slint";
            export { ClockState } from "clock_state.slint";
            export component AppWindow inherits Window { }
            "#,
        )
        .unwrap();
        let exports = parse_slint_exports(&path).unwrap();
        assert!(exports.iter().any(|n| n == "UI"));
        assert!(exports.iter().any(|n| n == "ClockState"));
        assert!(exports.iter().any(|n| n == "AppWindow"));
    }
}
