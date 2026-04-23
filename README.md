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
- Hooks: pure Rust functions invokable from Slint on a background thread, for native work that doesn't need to cross the Elixir protocol. See [docs/hooks.md](docs/hooks.md).

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
- Codegen generates a Slint `export struct` and `[Struct]` model property for each `:id_table` field (see below).
- Generated bindings connect patch paths to concrete Slint property setters.

### Hooks (native Rust extensions)

For work that shouldn't cross the Elixir protocol — generating a QR code from a URL, decoding a barcode, fast local validation — Projection supports hooks: pure Rust functions annotated with `#[hook]` that Slint can invoke on a background thread.

A hook named `qr_image(url: SharedString) -> Image` becomes the Slint global `QrImageHook` with `invoke(url)`, `result`, `loading`, and `error`. Elixir is not involved and does not know hooks exist.

Consumers write hooks in `slint/ui_host/src/hooks/mod.rs` (scaffolded on first `mix compile`). Everything else — Cargo build-dep, Slint re-export, `main.rs` wiring — is handled by Projection.

See [docs/hooks.md](docs/hooks.md) for the full guide.

## Install

Add Projection to your app dependencies:

```elixir
defp deps do
  [
    {:projection, "~> 0.1.0"}
  ]
end
```

## New project setup

Setup is a few files. The examples below use `my_app` / `MyApp` — substitute your own names.

### 1. Mix project

Create `mix.exs` with the Projection compilers:

```elixir
defmodule MyApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :my_app,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      compilers: Mix.compilers() ++ [:projection_codegen, :projection_ui_host],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MyApp.Application, []}
    ]
  end

  defp deps do
    [
      {:projection, "~> 0.1.0"}
    ]
  end
end
```

### 2. Config

Create `config/config.exs`:

```elixir
import Config

config :projection,
  otp_app: :my_app,
  router_module: MyApp.Router

config :logger, :default_formatter, metadata: [:sid, :rev, :screen]
```

Optional config keys:

- `otp_apps: [:my_app, :my_app_web]` — multi-app module discovery
- `screen_modules: [MyApp.Screens.Hello]` — explicit extra screen discovery
- `ui_root: "lib/my_app/ui"` — override Slint shell location (default: `lib/<otp_app>/ui`)

### 3. Router and screen

```elixir
# lib/my_app/router.ex
defmodule MyApp.Router do
  use Projection.Router.DSL

  screen_session :main do
    screen "/hello", MyApp.Screens.Hello, :show, as: :hello
  end
end
```

```elixir
# lib/my_app/screens/hello.ex
defmodule MyApp.Screens.Hello do
  use ProjectionUI, :screen

  schema do
    field :title, :string, default: "Hello Projection"
    field :subtitle, :string, default: "Elixir owns state. Slint renders it."
    field :message, :string, default: "Press the button to send an intent."
    field :click_count, :integer, default: 0
  end

  @impl true
  def handle_event("hello.click", _payload, state) do
    next_count = Map.get(state.assigns, :click_count, 0) + 1

    {:noreply,
     state
     |> assign(:click_count, next_count)
     |> assign(:message, "Hello from Elixir (click #{next_count})")}
  end

  def handle_event(_event, _payload, state), do: {:noreply, state}
end
```

### 4. Slint shell files

Create these four files under `lib/my_app/ui/`. Codegen requires them.

`lib/my_app/ui/ui.slint`:

```slint
export global UI {
    callback intent(intent_name: string, intent_arg: string);
}
```

`lib/my_app/ui/screen.slint`:

```slint
import { UI } from "ui.slint";

export component Screen inherits VerticalLayout {
    callback intent(intent_name: string, intent_arg: string);
    intent(intent_name, intent_arg) => {
        UI.intent(intent_name, intent_arg);
    }
}
```

`lib/my_app/ui/error.slint`:

```slint
import { Screen } from "screen.slint";

export component ErrorScreen inherits Screen {
    in property <string> title: "Rendering Error";
    in property <string> message: "";
    in property <string> screen_module: "";

    spacing: 12px;
    padding: 8px;

    Text {
        text: root.title;
        font-size: 16px;
        font-weight: 600;
        color: #cc4444;
    }

    Text {
        text: root.message;
        wrap: word-wrap;
        font-size: 13px;
        color: #c0c0d0;
    }

    Text {
        text: "Module: " + root.screen_module;
        font-size: 11px;
        color: #666688;
    }
}
```

`lib/my_app/ui/app_shell.slint`:

```slint
export component AppShell inherits Rectangle {
    in property <string> app_title: "Projection";
    in property <string> active_tab: "";
    in property <bool> show_back: false;
    in property <length> window_width: 480px;
    in property <length> window_height: 320px;

    callback nav_back();
    callback navigate(route_name: string);

    background: #1a1a2e;

    VerticalLayout {
        padding: 16px;
        spacing: 0px;

        HorizontalLayout {
            height: 36px;
            spacing: 12px;

            if root.show_back: Rectangle {
                width: 60px;
                height: 32px;
                border-radius: 6px;
                background: back_touch.has-hover ? #2a2a4a : #232342;

                Text {
                    text: "\u{2190} Back";
                    font-size: 13px;
                    color: #8888bb;
                    horizontal-alignment: center;
                    vertical-alignment: center;
                }

                back_touch := TouchArea {
                    clicked => { root.nav_back(); }
                }
            }

            Text {
                text: root.app_title;
                font-size: 18px;
                font-weight: 600;
                color: #e0e0f0;
                vertical-alignment: center;
            }
        }

        Rectangle {
            height: 1px;
            background: #2a2a4a;
        }

        VerticalLayout {
            padding-top: 12px;
            @children
        }
    }
}
```

### 5. Screen Slint file

Each screen needs a matching `.slint` file. For the hello screen above:

`lib/my_app/ui/hello.slint`:

```slint
import { Screen } from "screen.slint";

export component HelloScreen inherits Screen {
    in property <string> title: "Hello Projection";
    in property <string> subtitle: "Elixir owns state. Slint renders it.";
    in property <string> message: "Press the button to send an intent.";
    in property <int> click_count: 0;

    spacing: 12px;
    padding: 12px;

    Text {
        text: root.title;
        font-size: 22px;
        font-weight: 700;
        color: #f2f2ff;
    }

    Text {
        text: root.subtitle;
        wrap: word-wrap;
        color: #b8b8d0;
        font-size: 13px;
    }

    Rectangle { height: 1px; background: #2a2a4a; }

    Text {
        text: root.message;
        wrap: word-wrap;
        color: #d8d8f0;
        font-size: 15px;
    }

    Rectangle {
        height: 34px;
        border-radius: 6px;
        background: touch.has-hover ? #2a2a4a : #232342;

        Text {
            text: "Say Hello";
            horizontal-alignment: center;
            vertical-alignment: center;
            color: #cfcfe7;
            font-size: 13px;
            font-weight: 600;
        }

        touch := TouchArea {
            clicked => { root.intent("hello.click", ""); }
        }
    }
}
```

### 6. Rust UI host

Create a thin Rust adapter crate at `slint/ui_host/`. This references Projection's shared runtime from `deps/`.

`slint/ui_host/Cargo.toml`:

```toml
[package]
name = "ui_host"
version = "0.1.0"
edition = "2024"

[dependencies]
projection_ui_host_runtime = { path = "../../deps/projection/slint/ui_host_runtime" }
serde_json = "1.0.149"
slint = { version = "=1.15.0", default-features = false, features = ["std", "backend-winit", "renderer-software", "compat-1-2"] }

[build-dependencies]
slint-build = "=1.15.0"
```

`slint/ui_host/src/main.rs`:

```rust
mod generated;

slint::include_modules!();

projection_ui_host_runtime::app_main!(AppWindow, UI, ErrorState, generated);
```

Create the generated output directory:

```bash
mkdir -p slint/ui_host/src/generated
touch slint/ui_host/src/generated/.gitkeep
```

### 7. Build and run

```bash
mix deps.get
mix compile      # runs codegen + builds the Rust ui_host
```

To launch for development, create a small entry point:

```elixir
# lib/my_app/demo.ex
defmodule MyApp.Demo do
  def run do
    suffix = if match?({:win32, _}, :os.type()), do: ".exe", else: ""

    command =
      :my_app
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("ui_host/ui_host" <> suffix)

    {:ok, _supervisor} =
      Projection.start_session(
        name: MyApp.ProjectionSupervisor,
        session_name: MyApp.ProjectionSession,
        host_bridge_name: MyApp.ProjectionHostBridge,
        router: MyApp.Router,
        route: "hello",
        command: command
      )

    Process.sleep(:infinity)
  end
end
```

```bash
mix run -e "MyApp.Demo.run()"
```

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

## id_table fields and Slint structs

`:id_table` fields are for collections where row-level updates matter. The Elixir side
uses a keyed map structure (`%{order: [...], by_id: %{...}}`), and the Session diffs
only the rows that changed.

Codegen automatically generates a Slint struct and a single `[Struct]` model property
for each `:id_table` field:

```elixir
schema do
  field :devices, :id_table,
    columns: [name: :string, status: :string, online: :bool],
    default: %{order: [], by_id: %{}}
end
```

This generates:

```slint
export struct DevicesRow {
    id: string,
    name: string,
    status: string,
    online: bool,
}

export global DevicesState {
    in property <[DevicesRow]> devices: [];
}
```

In your screen `.slint` file, import the struct type and declare the model
as an `in property`:

```slint
import { DevicesRow } from "devices_types.slint";

export component DevicesScreen inherits Screen {
    in property <[DevicesRow]> devices: [];

    for device[index] in root.devices: DeviceCard {
        name: device.name;
        status: device.status;
        online: device.online;
        card-tapped(idx) => { root.show-sheet(idx); }
    }
}
```

You can also store a whole row as a single property, which is useful for
detail sheets or selected-item state:

```slint
property <DevicesRow> selected:
    root.selected_index >= 0 ? root.devices[root.selected_index] : { };
```

### Naming conventions

The struct name is derived from the field name: `devices` becomes `DevicesRow`,
`sensor_readings` becomes `SensorReadingsRow`.

The types file name matches the screen module's last segment (underscored),
the same convention as the generated state files:

| Screen module | Types file | State file |
|---|---|---|
| `MyApp.Screens.Home` | `home_types.slint` | `home_state.slint` |
| `MyApp.Screens.Devices` | `devices_types.slint` | `devices_state.slint` |
| `MyApp.Screens.DeviceDetail` | `device_detail_types.slint` | `device_detail_state.slint` |

Types files are generated in `slint/ui_host/src/generated/` alongside the
other generated files. The generated directory is added to the Slint include
path in `build.rs`, so your screen files import by bare filename — no path
prefix needed.

### Struct fields

The struct always includes an `id: string` field (from the id_table's `order`
array) followed by one field per declared column, mapped to Slint types:

| Elixir column type | Slint struct field type |
|---|---|
| `:string` | `string` |
| `:integer` | `int` |
| `:float` | `float` |
| `:bool` | `bool` |

On the Rust side, codegen generates a helper that parses the id_table JSON and
constructs a `VecModel<Struct>` with one row per entry. The generated
`screen_host.slint` passes the model to the screen as a property binding
automatically.

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

## Development: live-preview

When `MIX_ENV=dev`, `mix compile` automatically builds the Slint host with
`slint/live-preview` enabled. The host watches its `.slint` files on disk and
reloads them in-process when you save — no `cargo` rebuild and no Elixir
restart. Properties, models, and callbacks are preserved across reloads, so an
active session keeps running.

What each edit triggers:

| Edit | Action needed |
|---|---|
| `.slint` under `lib/<your_app>/ui/` (colors, layout, bindings) | save — reload is automatic |
| ProjectionUI Elixir module (fields, screens) | `mix projection.codegen` — reload on file write |
| Rust hook or runtime | `mix compile` (rebuild) |

Escape hatches:

- `PROJECTION_LIVE_PREVIEW=0 mix compile` — opt out of live-preview locally.
  Useful for reproducing prod-path behavior and for CI runs that stay in
  `MIX_ENV=dev`.
- `MIX_ENV=test` and `MIX_ENV=prod` never enable live-preview. Combining
  `PROJECTION_LIVE_PREVIEW=1` with `MIX_ENV=prod` is a hard error.

Live-preview artifacts live under `slint/ui_host/target/live-preview/` so they
do not clobber plain debug or release builds.

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
