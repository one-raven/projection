defmodule ProjectionUI do
  @moduledoc """
  UI-layer entrypoint for Projection screen and component modules.

  Projection follows the same reactive model as Phoenix LiveView: Elixir owns
  all state, the UI renders a projection of that state, and user interactions
  flow back as events. This module provides the macros that wire up screens
  and components with the schema DSL, state helpers, and lifecycle callbacks.

  ## Module types

  | Macro | Purpose |
  |-------|---------|
  | `use ProjectionUI, :screen` | Screen with full lifecycle (mount, handle_event, handle_info, render) |
  | `use ProjectionUI, :component` | Static component — schema only, no lifecycle |
  | `use ProjectionUI, :live_component` | Stateful component — own lifecycle (mount, update, handle_event, render, terminate) |
  | `use ProjectionUI, :app_state` | App-level state that persists across screen transitions |

  ## Screens

  Screens are the primary building block. They declare a typed schema, handle
  events from the Slint UI, and the framework automatically diffs and patches
  only the fields that changed.

      defmodule MyApp.Screens.Dashboard do
        use ProjectionUI, :screen

        schema do
          field :temperature, :float, default: 0.0
          field :status, :string, default: "idle"
        end

        @impl true
        def mount(_params, _session, state) do
          {:ok, assign(state, :status, "ready")}
        end

        @impl true
        def handle_event("refresh", _params, state) do
          {:noreply, assign(state, :status, "refreshing")}
        end
      end

  See `ProjectionUI.Screen` for the full callback reference.

  ## Static components

  Static components define a reusable schema (e.g. style defaults) with no
  lifecycle. Their fields are flattened with a prefix in the Slint bindings.

      defmodule MyApp.Components.Button do
        use ProjectionUI, :component

        schema do
          field :height, :integer, default: 34
        end
      end

  ## Live components

  Live components have their own state and lifecycle, managed by the Session.
  They can derive state from parent data, handle their own events, and manage
  internal concerns like scoring or display logic.

      defmodule MyApp.Components.Board do
        use ProjectionUI, :live_component

        schema do
          field :values, :list, items: :integer, direction: :in
          derived :labels, :list, items: :string, from: :values, with: {__MODULE__, :to_labels}
        end

        def to_labels(values), do: Enum.map(values, &to_string/1)
      end

  Both static and live components are declared in a screen schema with `component/3`:

      schema do
        component :button, MyApp.Components.Button       # static
        component :board, MyApp.Components.Board          # live (auto-detected)
      end

  See `ProjectionUI.LiveComponent` for the full lifecycle reference.

  ## Key features

  ### Derived fields

  Fields that are automatically computed from other fields. Eliminates manual
  derivation in `update/2` callbacks. See `ProjectionUI.Schema.derived/3`.

      schema do
        field :celsius, :float
        derived :fahrenheit, :float, from: :celsius, with: {__MODULE__, :to_f}
      end

  ### Async assigns

  Framework-managed async operations with automatic loading/ok/failed states.
  See `ProjectionUI.State.async_assign/3` and `ProjectionUI.AsyncResult`.

      def handle_event("load", _params, state) do
        {:noreply, async_assign(state, :data, fn -> fetch_data() end)}
      end

  ### Explicit effects

  Side effects returned as data from callbacks, executed by the Session.

      def handle_event("start", _params, state) do
        {:noreply, state,
          effects: [
            {:async, fn -> compute() end, :result},
            {:send_after, :timeout, 5000}
          ]}
      end

  ### Property direction

  Component fields can declare data flow direction (`:in`, `:out`, `:in_out`)
  to enforce clean parent-child contracts. See `ProjectionUI.Schema.field/3`.

  ### Component cleanup

  Screens and live components receive `terminate/2` when navigating away or
  shutting down, enabling resource cleanup.
  """

  @doc false
  def screen do
    quote do
      @behaviour ProjectionUI.Screen

      alias ProjectionUI.State
      import ProjectionUI.State, only: [assign: 3, update: 3, async_assign: 3]
      use ProjectionUI.Schema, owner: :screen

      @doc false
      @spec mount(map(), map(), State.t()) :: {:ok, State.t()}
      @impl true
      def mount(_params, _session, state) do
        {:ok, state}
      end

      @doc false
      @spec handle_event(String.t(), map(), State.t()) :: {:noreply, State.t()}
      @impl true
      def handle_event(_event, _params, state) do
        {:noreply, state}
      end

      @doc false
      @spec handle_params(map(), State.t()) :: {:noreply, State.t()}
      @impl true
      def handle_params(_params, state) do
        {:noreply, state}
      end

      @doc false
      @spec handle_info(any(), State.t()) :: {:noreply, State.t()}
      @impl true
      def handle_info(_message, state) do
        {:noreply, state}
      end

      @doc false
      @spec subscriptions(map(), map()) :: [term()]
      @impl true
      def subscriptions(_params, _session) do
        []
      end

      @doc false
      @spec render(map()) :: map()
      @impl true
      def render(assigns) when is_map(assigns) do
        defaults = schema()

        if map_size(defaults) == 0 do
          assigns
        else
          defaults
          |> Map.merge(Map.take(assigns, Map.keys(defaults)))
        end
      end

      @doc false
      @spec __projection_screen__() :: true
      def __projection_screen__, do: true

      @doc false
      @spec terminate(atom(), State.t()) :: :ok
      @impl true
      def terminate(_reason, _state), do: :ok

      defoverridable mount: 3,
                     handle_event: 3,
                     handle_params: 2,
                     handle_info: 2,
                     subscriptions: 2,
                     render: 1,
                     terminate: 2
    end
  end

  @doc false
  def app_state do
    quote do
      @behaviour ProjectionUI.AppState

      alias ProjectionUI.State
      import ProjectionUI.State, only: [assign: 3, update: 3]
      use ProjectionUI.Schema, owner: :app_state

      @doc false
      @spec mount(State.t()) :: {:ok, State.t()}
      @impl true
      def mount(state) do
        {:ok, state}
      end

      @doc false
      @spec __projection_app_state__() :: true
      def __projection_app_state__, do: true

      @before_compile ProjectionUI.AppState

      defoverridable mount: 1
    end
  end

  @doc false
  def component do
    quote do
      use ProjectionUI.Schema, owner: :component

      @doc false
      @spec __projection_component__() :: true
      def __projection_component__, do: true
    end
  end

  @doc false
  def live_component do
    quote do
      @behaviour ProjectionUI.LiveComponent

      alias ProjectionUI.State
      import ProjectionUI.State, only: [assign: 3, update: 3, async_assign: 3]
      use ProjectionUI.Schema, owner: :component

      @doc false
      @spec __projection_component__() :: true
      def __projection_component__, do: true

      @doc false
      @spec __projection_live_component__() :: true
      def __projection_live_component__, do: true

      @doc false
      @spec mount(map(), State.t()) :: {:ok, State.t()}
      @impl true
      def mount(_assigns, state) do
        {:ok, state}
      end

      @doc false
      @spec update(map(), State.t()) :: {:ok, State.t()}
      @impl true
      def update(assigns, state) do
        {:ok, Enum.reduce(assigns, state, fn {k, v}, acc -> assign(acc, k, v) end)}
      end

      @doc false
      @spec handle_event(String.t(), map(), State.t()) :: {:noreply, State.t()}
      @impl true
      def handle_event(_event, _payload, state) do
        {:noreply, state}
      end

      @doc false
      @spec render(map()) :: map()
      @impl true
      def render(assigns) when is_map(assigns) do
        defaults = schema()

        if map_size(defaults) == 0 do
          assigns
        else
          defaults
          |> Map.merge(Map.take(assigns, Map.keys(defaults)))
        end
      end

      @doc false
      @spec terminate(atom(), State.t()) :: :ok
      @impl true
      def terminate(_reason, _state), do: :ok

      defoverridable mount: 2,
                     update: 2,
                     handle_event: 3,
                     render: 1,
                     terminate: 2
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
