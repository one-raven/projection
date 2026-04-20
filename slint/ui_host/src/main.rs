mod generated;
mod hooks;

slint::include_modules!();

include!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/generated_hooks/register.rs"));

projection_ui_host_runtime::app_main!(AppWindow, UI, ErrorState, generated, register_hooks);
