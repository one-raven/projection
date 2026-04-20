use std::path::Path;

fn main() {
    let hooks_entry = Path::new("src/hooks/mod.rs");
    let app_slint = Path::new("src/generated/app.slint");
    let hooks_out = Path::new("src/generated_hooks");

    let emit = projection_ui_host_codegen::scan_and_emit(hooks_entry, app_slint, hooks_out)
        .expect("hook codegen failed");

    for path in &emit.scanned_files {
        println!("cargo:rerun-if-changed={}", path.display());
    }
    println!("cargo:rerun-if-changed=src/hooks");
    println!("cargo:rerun-if-changed=src/generated/app.slint");
    println!("cargo:rerun-if-changed=src/generated/screen_host.slint");
    println!("cargo:rerun-if-changed=src/generated/routes.slint");
    println!("cargo:rerun-if-changed=src/generated/error_state.slint");
    println!("cargo:rerun-if-changed=../../lib/projection/ui/");

    let config = slint_build::CompilerConfiguration::new()
        .with_include_paths(vec!["src/generated".into(), "src/generated_hooks".into()]);
    slint_build::compile_with_config("src/generated_hooks/root.slint", config)
        .expect("failed to compile root.slint");
}
