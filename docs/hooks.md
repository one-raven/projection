# Hooks

Hooks let a Slint UI invoke pure Rust functions on a background thread and
receive the result back as reactive properties. They exist for work that
Elixir shouldn't or can't do — native libraries, image processing, on-device
validation — without adding a Slint↔Elixir round trip.

> **Elixir owns truth. Slint renders a projection of that truth. Rust bridges
> the two.** Hooks live squarely in the Rust bridge: they never cross the
> Elixir protocol, and Elixir is deliberately unaware of them.

Design-wise they are loosely inspired by
[Phoenix LiveView JS hooks](https://hexdocs.pm/phoenix_live_view/js-interop.html):
a named client-side extension point that owns a small piece of local
presentation behavior without the server caring.

## When to use a hook

Reach for a hook when **all** of the following are true:

- The work is a pure transformation of local inputs (no domain authority needed).
- Elixir doesn't need the result — only the UI does.
- A native library or Rust-specific API is the right tool (image generation,
  barcode decoding, format conversion, fast regex validation).

Do **not** reach for a hook when:

- The result must be persisted, audited, or re-validated server-side — do that
  in Elixir, then push the result through the normal schema.
- You're tempted to use it for state management — use Elixir state instead.
- The operation has side effects that need to survive restart.

## Authoring a hook

Every hook is a `pub fn` in `slint/ui_host/src/hooks/mod.rs`, annotated with
`#[hook]`. The signature is the whole contract — inputs, output type, and hook
name (which becomes the Slint global name) are all derived from it.

```rust
// slint/ui_host/src/hooks/mod.rs
use projection_ui_host_runtime::hook;
use slint::SharedString;

#[hook]
pub fn uppercase(text: SharedString) -> SharedString {
    text.to_uppercase().into()
}
```

A hook named `uppercase` becomes a Slint global `UppercaseHook`. Snake case
converts to PascalCase.

### Supported types

| Rust type                     | Slint type |
|-------------------------------|------------|
| `slint::SharedString`, `String` | `string`   |
| `i32`, `i64`, `u32`, `isize`  | `int`      |
| `f32`, `f64`                  | `float`    |
| `bool`                        | `bool`     |
| `slint::Image`                | `image`    |

Inputs and outputs must use these types. Multi-value output via struct return
is not yet supported; pick the most useful single value.

## Using a hook from Slint

The generated global exposes:

- `invoke(args…)` — a callback the UI triggers to start the hook
- `result: T` — the most recent returned value (last-good during loading)
- `loading: bool` — true while a background thread is in flight
- `error: string` — non-empty if the hook panicked

The UI owns when to fire the hook. The common pattern is to forward a Slint
property change into `invoke`:

```slint
import { UppercaseHook } from "hooks.slint";

Text {
    text: UppercaseHook.result;
    opacity: UppercaseHook.loading ? 0.5 : 1.0;
}

input := TextInput { }
changed input.text => { UppercaseHook.invoke(input.text); }

if UppercaseHook.error != "": Text {
    text: UppercaseHook.error;
    color: red;
}
```

A hook driven by Elixir data looks the same, except the trigger is a change
on a schema-driven global:

```slint
init => { QrImageHook.invoke(HomeState.setup_url); }
changed HomeState.setup_url => { QrImageHook.invoke(HomeState.setup_url); }

Image { source: QrImageHook.result; }
```

### Triggering on load

Use Slint's `init => { }` callback to fire a hook once when the view mounts.
`init` runs exactly one time per component instance, after the component's
properties have their initial values (including anything Elixir pushed in the
first `render`).

If the value never changes after load, `init` alone is enough:

```slint
init => { QrImageHook.invoke(root.setup_url); }
Image { source: QrImageHook.result; }
```

If the value can change later, pair `init` with `changed` so the hook runs
both on mount and on every subsequent update:

```slint
function refresh() { QrImageHook.invoke(root.setup_url); }
init => { refresh(); }
changed setup_url => { refresh(); }
```

**Gotcha: initial-value emptiness.** If the screen mounts before Elixir has
pushed the real value — e.g. it's fetched asynchronously — `init` fires with
whatever default the property has (usually `""`). Guard the call so the hook
isn't invoked with garbage input:

```slint
init => {
    if (root.setup_url != "") { QrImageHook.invoke(root.setup_url); }
}
```

The `changed` block still picks up the real value when it arrives. Skipping
`init` entirely and relying only on `changed` is not a reliable substitute:
`changed` does not fire for the first value assignment if the property's
initial value is already that same value.

## Lifecycle and guarantees

- **Runs on a worker thread.** Every invocation calls `std::thread::spawn` and
  marshals the result back to the Slint UI thread with
  `slint::invoke_from_event_loop`. The UI stays responsive during long work.
- **Cancellation via generation counter.** Each call to `invoke` bumps a
  counter; when a worker finishes it checks its generation is still current
  and otherwise drops the result. Rapid-fire inputs don't produce flickering
  stale outputs — the latest call wins.
- **Last-good on loading.** `result` retains its previous value while
  `loading` is true. To blank it out during loading, write
  `UppercaseHook.loading ? "" : UppercaseHook.result` in the binding.
- **Panic = log-and-skip.** `catch_unwind` wraps the hook body. On panic,
  `error` is set (to the panic message if it's a string), `result` is left at
  its last-good value, and `loading` clears. The framework does not crash.
- **No hook-to-Elixir path.** A hook cannot emit an intent. If you need to
  notify Elixir of something a hook computed, do it from Slint by calling
  `intent(...)` separately, after reading the hook's `result`.

## Project checklist

To add a hook to a project:

1. Add the function to `slint/ui_host/src/hooks/mod.rs` with `#[hook]`.
2. Add any new Rust dependency the hook needs to `slint/ui_host/Cargo.toml`.
3. Run `cargo build` (or `mix compile`). The scanner regenerates:
   - `slint/ui_host/src/generated_hooks/hooks.slint` — the global
   - `slint/ui_host/src/generated_hooks/root.slint` — Slint entry that
     re-exports everything
   - `slint/ui_host/src/generated_hooks/register.rs` — the Rust glue
4. Import the generated global in your screen's `.slint` file:
   `import { MyHook } from "hooks.slint";`
5. Trigger it from Slint with `MyHook.invoke(...)` and read `MyHook.result`.

The `src/generated_hooks/` directory is gitignored; files are produced by
`build.rs` on every build.

## Constraints in the current version

- Hooks must be declared at the top level of `src/hooks/mod.rs`. Submodules
  under `src/hooks/` are not yet scanned.
- Hooks must be `pub fn`, non-generic, and not `async fn`.
- `#[hook(sync)]` is reserved for a future sync-callback variant (`pure
  callback` for fast inline hooks). It currently errors at build time.
- Each hook runs its work on a fresh `std::thread::spawn`; a shared thread
  pool is a future optimization if rapid-fire calls become a pattern.
- Only one invocation per hook is meaningful at a time (older calls are
  cancelled by generation counter). For multiple parallel results with
  different inputs, define separate hooks.

## Debugging

- Build failures in hook codegen point at `src/hooks/mod.rs` with a message
  naming the offending function and the unsupported type.
- Runtime panics surface as `MyHook.error`. Inspect stderr for the full
  backtrace — `catch_unwind` records the message only.
- If a Slint import can't resolve a hook global, check that the function is
  `pub`, has `#[hook]`, and that `cargo build` regenerated the artifacts.
  The generated `hooks.slint` is the source of truth for what names exist.

## Why not do this in Elixir?

Hooks specifically trade off Elixir's strengths (durability, auditability,
authority) for latency and access to native libraries. If either of those
wins matters for your case, a hook is correct. If neither matters, the work
belongs in Elixir — keep the authority model simple.
