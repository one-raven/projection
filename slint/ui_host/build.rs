fn main() {
    let config = slint_build::CompilerConfiguration::new()
        .with_include_paths(vec!["../../lib/projection/ui/types".into()]);
    slint_build::compile_with_config("src/generated/app.slint", config).expect("failed to compile app.slint");

    println!("cargo:rerun-if-changed=src/generated/app.slint");
    println!("cargo:rerun-if-changed=src/generated/screen_host.slint");
    println!("cargo:rerun-if-changed=src/generated/routes.slint");
    println!("cargo:rerun-if-changed=src/generated/error_state.slint");
    println!("cargo:rerun-if-changed=../../lib/projection/ui/");
    println!("cargo:rerun-if-changed=../../lib/projection/ui/types/");
}
