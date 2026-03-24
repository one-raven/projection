defmodule ProjectionUI.LiveComponent do
  @moduledoc """
  Behaviour for stateful Projection components.

  Live components encapsulate a slice of the UI with their own state and lifecycle,
  similar to `Phoenix.LiveComponent` in LiveView. They are declared in a screen's
  schema using the same `component/3` macro — the framework detects live components
  automatically when the module exports `__projection_live_component__/0`.

  ## Lifecycle

  Live components have four callbacks, all optional with sensible defaults:

  | Callback | Called when | Purpose |
  |----------|-----------|---------|
  | `mount/2` | Screen first mounts | Initialize component state |
  | `update/2` | Parent pushes new assigns | Merge or transform incoming data |
  | `handle_event/3` | Component-scoped intent arrives | Handle user interactions |
  | `render/1` | After any state change | Produce the component's view-model |

  ## Defining a live component

      defmodule MyApp.Components.Sidebar do
        use ProjectionUI, :live_component

        schema do
          field :status, :string, default: ""
          field :items, :list, items: :string, default: []
        end

        @impl true
        def update(assigns, state) do
          # Only accept fields this component controls.
          # Ignore derived or unknown keys to avoid overwriting computed state.
          state =
            Enum.reduce(assigns, state, fn
              {:status, v}, state -> assign(state, :status, v)
              {:items, v}, state -> assign(state, :items, v)
              _other, state -> state
            end)

          {:ok, state}
        end
      end

  ## Using in a screen

  Declare the component in the screen's schema — the same `component/3` macro
  works for both static and live components:

      defmodule MyApp.Screens.Dashboard do
        use ProjectionUI, :screen

        schema do
          component :sidebar, MyApp.Components.Sidebar
          field :title, :string, default: "Dashboard"
        end

        def handle_event("refresh", _params, state) do
          {:noreply, assign(state, :sidebar, %{status: "Refreshing..."})}
        end
      end

  When the screen assigns to `:sidebar`, the Session detects the change and calls
  `Sidebar.update/2` with the new assigns. The component's `render/1` then produces
  its portion of the view-model, which the codegen flattens with a prefix
  (`sidebar_status`, `sidebar_items`) in the generated Slint bindings.

  ## Derived state

  A common pattern is for the parent to push raw data and the component to derive
  display-specific state in `update/2`:

      defmodule MyApp.Components.Board do
        use ProjectionUI, :live_component

        schema do
          field :values, :list, items: :integer, default: []
          field :labels, :list, items: :string, default: []
        end

        @impl true
        def update(assigns, state) do
          state =
            Enum.reduce(assigns, state, fn
              {:values, vals}, state ->
                state
                |> assign(:values, vals)
                |> assign(:labels, Enum.map(vals, &to_string/1))

              _other, state -> state
            end)

          {:ok, state}
        end
      end

  **Important:** When using derived fields, the `update/2` callback should only
  accept the fields the parent explicitly controls and ignore derived fields.
  Otherwise, schema default values (e.g. `labels: []`) passed during initial
  mount will overwrite the derived values.

  ## Component-scoped events

  Events can be routed directly to a live component using a naming convention.
  Intent names prefixed with `"component_name:"` are dispatched to the component's
  `handle_event/3` instead of the parent screen:

      # In Slint:
      root.intent("sidebar:clear", "")

      # Routes to:
      Sidebar.handle_event("clear", %{}, component_state)

  ## How it works internally

  1. Screen mounts → Session inspects schema for live components → calls `mount/2`
     then `update/2` with initial assigns for each live component
  2. Screen assigns to a component key → Session detects the change → calls `update/2`
  3. Intent with `"component:"` prefix arrives → Session routes to `handle_event/3`
  4. After any state change, Session calls `render/1` and overlays the result onto
     the screen's view-model before computing patches

  No changes to the Slint/Rust layer or codegen are needed — live components are
  an Elixir-side feature that reuses the existing component field expansion.

  ## Field direction

  Component fields support a `:direction` option that controls data flow between
  the parent screen and the component:

    * `:in` (default) — the parent can push values; the component reads them
    * `:out` — the component produces values; the parent cannot push to this field
    * `:in_out` — bidirectional; both parent and component can read/write

  When the parent screen assigns to a component key, only `:in` and `:in_out`
  fields are forwarded to `update/2`. Fields marked `:out` are filtered out,
  preventing the parent from accidentally overwriting component-owned state.

      schema do
        field :raw_data, :list, items: :string, direction: :in
        field :display_label, :string, direction: :out
      end

  ## Static vs live components

  | Aspect | Static (`use ProjectionUI, :component`) | Live (`use ProjectionUI, :live_component`) |
  |--------|----------------------------------------|-------------------------------------------|
  | Schema | Yes | Yes |
  | Lifecycle | None | mount, update, handle_event, render |
  | State | Parent owns (plain map in assigns) | Component owns (managed by Session) |
  | Event handling | Parent handles all events | Component can handle scoped events |
  | Use case | Style defaults, config | Display logic, derived state, local interactions |
  """

  @doc """
  Called once when the parent screen mounts.

  Receives the initial assigns pushed by the parent (if any) and a fresh
  `State` initialized from the component's schema defaults.
  """
  @callback mount(assigns :: map(), state :: ProjectionUI.State.t()) ::
              {:ok, ProjectionUI.State.t()}

  @doc """
  Called when the parent screen pushes new assigns to this component.

  The `assigns` map contains only the keys the parent changed, not the full
  component state. Use pattern matching to accept known keys and ignore others:

      def update(assigns, state) do
        state =
          Enum.reduce(assigns, state, fn
            {:status, v}, state -> assign(state, :status, v)
            _other, state -> state
          end)

        {:ok, state}
      end
  """
  @callback update(assigns :: map(), state :: ProjectionUI.State.t()) ::
              {:ok, ProjectionUI.State.t()}

  @doc """
  Called when an intent scoped to this component arrives.

  Intents are scoped using the `"component_name:event_name"` naming convention.
  For example, `root.intent("sidebar:clear", "")` in Slint routes to
  `handle_event("clear", payload, state)` on the sidebar component.
  """
  @callback handle_event(event :: String.t(), payload :: map(), state :: ProjectionUI.State.t()) ::
              {:noreply, ProjectionUI.State.t()} | {:noreply, ProjectionUI.State.t(), keyword()}

  @doc """
  Produces the component's portion of the view-model.

  The default implementation merges the component's assigns with schema defaults,
  returning only schema-declared keys. Override to transform or filter the output.
  """
  @callback render(assigns :: map()) :: map()

  @doc """
  Called when the component is being shut down.

  `reason` is an atom describing why the component is terminating:
    * `:shutdown` — the session process is stopping
    * `:navigate` — the parent screen is navigating away
  """
  @callback terminate(reason :: atom(), state :: ProjectionUI.State.t()) :: :ok
end
