fn main() {
    slint_build::compile("src/generated/app.slint").expect("failed to compile app.slint");

    println!("cargo:rerun-if-changed=src/generated/app.slint");
    println!("cargo:rerun-if-changed=src/generated/screen_host.slint");
    println!("cargo:rerun-if-changed=src/generated/routes.slint");
    println!("cargo:rerun-if-changed=src/generated/error_state.slint");
    println!("cargo:rerun-if-changed=../../lib/projection/ui/");
}
