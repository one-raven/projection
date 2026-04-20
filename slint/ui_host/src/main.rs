mod generated;

slint::include_modules!();

projection_ui_host_runtime::app_main!(AppWindow, UI, ErrorState, generated);
