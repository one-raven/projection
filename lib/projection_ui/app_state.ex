defmodule ProjectionUI.AppState do
  @moduledoc """
  Callback behaviour for Projection app state modules.

  An app state module is a session-level stateful unit that provides
  application-wide state (e.g. clock, connection status) to the UI host.
  Unlike screens, app state persists across screen transitions and has
  no `handle_event`, `handle_params`, `subscriptions`, or `render` callbacks.

  Implement this behaviour via `use ProjectionUI, :app_state`.

  ## Lifecycle

    1. `c:mount/1` — called once when the session starts
    2. `c:handle_info/2` — called for messages (e.g. timer ticks)

  Default implementations for `c:mount/1` and `c:handle_info/2` are provided
  by the `use ProjectionUI, :app_state` macro.
  """

  alias ProjectionUI.State

  @doc "Returns default assigns as a `%{field_name => default_value}` map."
  @callback schema() :: map()

  @doc false
  @callback __projection_schema__() :: [map()]

  @callback mount(state :: State.t()) :: {:ok, State.t()}

  @callback handle_info(message :: any(), state :: State.t()) ::
              {:noreply, State.t()}

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      @doc false
      @impl true
      def handle_info(_message, state), do: {:noreply, state}
    end
  end
end
