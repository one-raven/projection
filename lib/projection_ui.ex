defmodule ProjectionUI do
  @moduledoc """
  UI-layer entrypoint for Projection screen and component modules.

  Use this module with the `:screen` atom to set up a screen:

      defmodule MyApp.Screens.Greeter do
        use ProjectionUI, :screen

        schema do
          field :greeting, :string, default: "Hello!"
        end
      end

  This imports `ProjectionUI.State` helpers (`assign/3`, `update/3`),
  applies the `ProjectionUI.Screen` behaviour, uses the `ProjectionUI.Schema`
  DSL, and provides default implementations for all optional callbacks.

  Reusable component schemas can be declared with `use ProjectionUI, :component`.

  App-level state (e.g. clock, connection status) that persists across screen
  transitions can be declared with `use ProjectionUI, :app_state`.
  """

  @doc false
  def screen do
    quote do
      @behaviour ProjectionUI.Screen

      alias ProjectionUI.State
      import ProjectionUI.State, only: [assign: 3, update: 3]
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

      defoverridable mount: 3,
                     handle_event: 3,
                     handle_params: 2,
                     handle_info: 2,
                     subscriptions: 2,
                     render: 1
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

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
