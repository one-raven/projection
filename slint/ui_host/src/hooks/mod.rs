//! User-authored hooks.
//!
//! Each `#[hook]` function is picked up at build time and exposed to Slint as a
//! global. Hooks run on a background thread; a `loading` output property is
//! held true while the hook is in flight and drops back to false when the
//! result (or a panic) returns to the UI thread.
//!
//! # Example
//!
//! ```ignore
//! use projection_ui_host_runtime::hook;
//! use slint::SharedString;
//!
//! #[hook]
//! pub fn uppercase(text: SharedString) -> SharedString {
//!     text.to_uppercase().into()
//! }
//! ```
//!
//! In Slint:
//!
//! ```slint
//! import { UppercaseHook } from "hooks.slint";
//!
//! init => { UppercaseHook.invoke("hello"); }
//! Text { text: UppercaseHook.result; color: UppercaseHook.loading ? grey : white; }
//! ```

use projection_ui_host_runtime::hook;
use slint::SharedString;

/// Reference hook: uppercases a string on a background thread.
///
/// The artificial sleep exists to make the `loading` state observable during
/// manual testing; remove it when copying this as a starting point.
#[hook]
pub fn uppercase(text: SharedString) -> SharedString {
    std::thread::sleep(std::time::Duration::from_millis(250));
    text.to_uppercase().into()
}
