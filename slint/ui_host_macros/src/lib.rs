//! Proc-macro surface for Projection hooks.
//!
//! A `#[hook]` function is picked up at build time by `projection_ui_host_codegen`,
//! which scans the crate's `src/hooks/` directory and emits Slint components plus
//! Rust binding glue into `src/generated_hooks/`.
//!
//! The attribute itself is a near-passthrough: it validates the argument shape
//! (`#[hook]` or `#[hook(sync)]`) so typos fail at the call site instead of
//! silently disappearing from the codegen output, and otherwise leaves the
//! function untouched so it can be called normally from the generated glue.

use proc_macro::TokenStream;

#[proc_macro_attribute]
pub fn hook(attr: TokenStream, item: TokenStream) -> TokenStream {
    let attr_str = attr.to_string();
    let trimmed = attr_str.trim();
    if !trimmed.is_empty() && trimmed != "sync" && trimmed != "async" {
        let msg = format!(
            "#[hook] accepts no arguments or `sync`/`async`; got `{trimmed}`"
        );
        let err: TokenStream = format!("compile_error!({msg:?});").parse().unwrap();
        let mut out = err;
        out.extend(item);
        return out;
    }
    item
}
