# Projection

Projection is an Elixir-authoritative UI runtime for native and embedded apps rendered by Slint.
It is for applications where you cannot or do not want to ship a browser runtime.

Projection is designed primarily for embedded UIs, and also runs well on macOS and Windows for local development and testing.

The design is heavily inspired by Phoenix LiveView: state and behavior stay in Elixir processes, while the client runtime renders and forwards intents.

`Elixir owns truth. Slint renders a projection of that truth. Rust bridges the two.`

This repository is the library core. It intentionally does not ship demo screens or a demo router.

> Note: This project is mostly AI-generated and is not yet hardened or tested for production systems.

## What it provides

- Session runtime (`Projection.Session`) for authoritative UI state.
- Port bridge runtime (`ProjectionUI.HostBridge`) for framed JSON envelopes over stdio.
- Router DSL (`Projection.Router.DSL`) for route-driven screen sessions.
- Schema DSL (`ProjectionUI.Schema`) for typed screen fields.
- Codegen (`mix projection.codegen`) for Rust/Slint typed bindings.
- Shared Rust host runtime crate (`slint/ui_host_runtime`) used by app-local `ui_host` adapters.
- Compile tasks (`mix compile.projection_codegen`, `mix compile.projection_ui_host`) that your app can opt into.

## Architecture

Projection has three runtime parts with clear boundaries:

- Elixir session process (`Projection.Session`):
  owns screen state, routing, validation, subscriptions, timers, and patch generation.
- Rust host (`ui_host`):
  owns transport and patch application to Slint properties/models.
- Slint UI:
  owns rendering, input handling, and local visual behavior.

### Authority model

- Elixir is the source of truth.
- Rust host is policy-free glue.
- Slint does not contain domain/business logic.

### Dual event-loop model

- BEAM/GenServer loop:
  handles intents/domain events, computes next state, emits `render`/`patch`.
- Slint UI loop:
  handles draw/input, applies property updates on the UI thread.

The host bridges those loops through framed stdio messages.

### Message lifecycle

1. UI host starts and sends `ready`.
2. Session responds with `render` (full VM snapshot).
3. User interaction emits `intent` to Elixir.
4. Session updates state and emits minimal `patch` operations with monotonic `rev`.
5. Host validates revision ordering, applies patch to Slint, and updates visible UI.

### Routing + screens

- Routes are declared in Elixir with `Projection.Router.DSL`.
- Each route resolves to a screen module using `use ProjectionUI, :screen`.
- Screen `schema do ... end` defines typed VM fields used by codegen.
- `:list` fields default to string lists; use `items: :integer | :float | :bool | :string` for typed lists.
- `:id_table` fields require typed columns, for example `columns: [name: :string, pos: :integer]`.
- Generated bindings connect patch paths to concrete Slint property setters.

## Install

Add Projection to your app dependencies:

```elixir
defp deps do
  [
    {:projection, "~> 0.1.0"}
  ]
end
```

## Starter generator

This repo also includes a companion Mix archive project at `projection_new/`.
It generates a ready-to-run Projection + Slint starter app (router, hello screen,
UI templates, and a thin `ui_host` adapter crate).

The generated app does not copy large host runtime files into your project.
The generated app references the shared Rust runtime crate directly from
`deps/projection/slint/ui_host_runtime`.

Requirement: use Projection from the default Mix deps location (`deps/projection`).

Build and install the archive locally:

```bash
cd projection_new
mix archive.build
mix archive.install
```

Generate a new app:

```bash
mix projection.new my_app
```

## Application setup

Projection codegen and ui_host build should run in your app project, not inside dependency compile steps.

In your app `mix.exs`, opt in to Projection compilers:

```elixir
def project do
  [
    app: :my_app,
    version: "0.1.0",
    elixir: "~> 1.19",
    compilers: Mix.compilers() ++ [:projection_codegen, :projection_ui_host],
    deps: deps()
  ]
end
```

In your app config:

```elixir
import Config

config :projection,
  otp_app: :my_app,
  router_module: MyApp.Router
```

Optional:

- `otp_apps: [:my_app, :my_app_web]` for multi-app module discovery.
- `screen_modules: [MyApp.Screens.Clock]` for explicit extra screen discovery.
- `ui_root: "lib/my_app/ui"` to override where Slint shell/screen files live. Default is `lib/<otp_app>/ui`.

Your app also owns the shared Slint shell files under `lib/<otp_app>/ui/`:

- `app_shell.slint`
- `ui.slint`
- `screen.slint`
- `error.slint`

`mix projection.new` scaffolds these for you.

## LiveView-style structure

Projection works best when you treat screens like LiveViews and components like LiveComponents.

| LiveView concept | Projection equivalent |
| --- | --- |
| `Phoenix.LiveView` module | `use ProjectionUI, :screen` module |
| `Phoenix.Component` / LiveComponent data contract | `use ProjectionUI, :component` schema |
| `assigns` | `ProjectionUI.State.assigns` |
| `handle_event/3` | `handle_event/3` on screen |
| `Phoenix router + live routes` | `Projection.Router.DSL` `screen` routes |
| root layout | `app_shell.slint` + `screen_host.slint` (generated) |

## Recommended app layout

Use this as the baseline structure for app code:

```text
my_app/
  lib/my_app/
    application.ex
    router.ex
    demo.ex
    screens/
      clock.ex
      devices.ex
    components/
      status_badge.ex
  lib/my_app/ui/
    app_shell.slint
    ui.slint
    screen.slint
    error.slint
    clock.slint
    devices.slint
    components/
      status_badge.slint
  slint/ui_host/
    Cargo.toml
    build.rs
    src/main.rs
    src/generated/
```

Notes:

- Keep Elixir screen modules in `lib/<app>/screens/`.
- Keep reusable schema components in `lib/<app>/components/`.
- Keep Slint files in `lib/<otp_app>/ui/`.
- Keep reusable Slint visuals in `lib/<otp_app>/ui/components/`.
- Define app window defaults in `app_shell.slint` via `window_width` / `window_height`.
- `slint/ui_host/src/main.rs` should stay thin. Shared runtime logic lives in Projection's `slint/ui_host_runtime` crate and is referenced from `../../deps/projection/slint/ui_host_runtime`.

## Screen and Slint naming convention

Codegen pairs screen modules to `.slint` files by module name:

- `MyApp.Screens.Clock` -> `lib/my_app/ui/clock.slint`
- `MyApp.Screens.DeviceDetail` -> `lib/my_app/ui/device_detail.slint`

The exported Slint component should be `<ModuleLastSegment>Screen`:

- `ClockScreen`
- `DeviceDetailScreen`

This convention keeps routes, screen modules, codegen output, and Slint imports aligned.

## Components (LiveComponent-style contracts)

Define reusable typed contracts with `use ProjectionUI, :component`, then embed them in screens with `component/2`.

```elixir
defmodule MyApp.Components.StatusBadge do
  use ProjectionUI, :component

  schema do
    field :label, :string, default: "Online"
    field :status, :string, default: "ok"
  end
end

defmodule MyApp.Screens.Clock do
  use ProjectionUI, :screen

  schema do
    field :clock_text, :string, default: "--:--:--"
    component :status_badge, MyApp.Components.StatusBadge
  end
end
```

For Slint bindings, component fields are flattened with a prefix:

- `status_badge.label` -> `status_badge_label`
- `status_badge.status` -> `status_badge_status`

## Define a screen

```elixir
defmodule MyApp.Screens.Clock do
  use ProjectionUI, :screen

  schema do
    field :clock_text, :string, default: "--:--:--"
    field :clock_running, :bool, default: true
  end

  @impl true
  def handle_event("clock.pause", _payload, state) do
    {:noreply, assign(state, :clock_running, false)}
  end
end
```

## Define routes

```elixir
defmodule MyApp.Router do
  use Projection.Router.DSL

  screen_session :main do
    screen "/clock", MyApp.Screens.Clock, :show, as: :clock
  end
end
```

## Start a runtime session

```elixir
{:ok, _sup} =
  Projection.start_session(
    name: MyApp.ProjectionSupervisor,
    session_name: MyApp.ProjectionSession,
    host_bridge_name: MyApp.ProjectionHostBridge,
    router: MyApp.Router,
    route: "clock",
    command: "/path/to/ui_host"
  )
```

You must pass either:

- `:router` for routed mode, or
- `:screen_module` for single-screen mode.

## Protocol model

The bridge uses framed JSON envelopes (`{:packet, 4}`):

- UI -> Elixir: `ready`, `intent`
- Elixir -> UI: `render`, `patch`, `error`

Patches use an RFC 6902 subset (`replace`, `add`, `remove`).

## Build and test

```bash
mix deps.get
mix projection.codegen
mix compile
mix test
```

## Observability

Runtime logs include structured metadata:

- `sid`
- `rev`
- `screen`

Telemetry events:

- `[:projection, :session, :intent, :received]`
- `[:projection, :session, :render, :complete]`
- `[:projection, :session, :patch, :sent]`
- `[:projection, :session, :error]`
- `[:projection, :host_bridge, :error]`
