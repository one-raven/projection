defmodule ProjectionUI.Screen do
  @moduledoc """
  Callback behaviour for Projection screen modules.

  A screen is a stateful UI unit — similar to a Phoenix LiveView — that declares
  a typed schema and handles lifecycle events. Implement this behaviour via
  `use ProjectionUI, :screen`, which provides default implementations for all
  optional callbacks.

  ## Lifecycle

    1. `c:mount/3` — called once when the screen is first loaded or navigated to
    2. `c:handle_params/2` — called on route patches (param changes without remount)
    3. `c:handle_event/3` — called for each user intent from the UI host
    4. `c:handle_info/2` — called for messages like `:tick` or pub/sub broadcasts
    5. `c:render/1` — produces the view-model map from current assigns
    6. `c:subscriptions/2` — declares pub/sub topics for this screen
    7. `c:terminate/2` — called when navigating away or shutting down

  All callbacks except `c:schema/0` and `c:__projection_schema__/0` are optional.

  ## Returning effects

  `c:handle_event/3`, `c:handle_info/2`, and `c:handle_params/2` can optionally
  return a third element with an effects list:

      def handle_event("solve", _params, state) do
        {:noreply, assign(state, :status, "solving"),
          effects: [
            {:async, fn -> Solver.compute(tiles) end, :solver_result},
            {:send_after, :check_timeout, 5000}
          ]}
      end

  Supported effects:

    * `{:async, fun, key}` — spawns a supervised task; sets `key` to
      `%AsyncResult{loading: true}` immediately, then `AsyncResult.ok(result)` or
      `AsyncResult.failed(reason)` when the task completes. Re-calling with the
      same key cancels the previous task.
    * `{:send_after, message, milliseconds}` — schedules a message to arrive
      via `c:handle_info/2` after the given delay.
    * `{:cancel_async, key}` — cancels an active async task for the given key.

  Effects are executed by the Session after state changes are applied and patches
  are sent, so the UI sees the immediate state update before async work begins.

  ## Async assigns

  For convenience, `async_assign/3` can be called directly in any callback
  to start an async operation without using the effects return:

      def mount(_params, _session, state) do
        {:ok, async_assign(state, :initial_data, fn -> fetch_data() end)}
      end

  See `ProjectionUI.State.async_assign/3` and `ProjectionUI.AsyncResult`.
  """

  alias ProjectionUI.State

  @doc "Returns default assigns as a `%{field_name => default_value}` map."
  @callback schema() :: map()

  @doc false
  @callback __projection_schema__() :: [map()]

  @doc """
  Called once when a screen is mounted.

  Receives route params, the session map, and an initial `t:ProjectionUI.State.t/0`
  pre-populated with schema defaults.
  """
  @callback mount(params :: map(), session :: map(), state :: State.t()) ::
              {:ok, State.t()}

  @doc """
  Handles a named user intent from the UI host.

  `event` is the intent name (e.g. `"clock.pause"`), and `params` is the
  intent payload map.
  """
  @callback handle_event(event :: String.t(), params :: map(), state :: State.t()) ::
              {:noreply, State.t()} | {:noreply, State.t(), keyword()}

  @doc """
  Called when route params change without a full remount (via `ui.route.patch`).
  """
  @callback handle_params(params :: map(), state :: State.t()) ::
              {:noreply, State.t()} | {:noreply, State.t(), keyword()}

  @doc """
  Handles internal messages such as `:tick` or pub/sub broadcasts.
  """
  @callback handle_info(message :: any(), state :: State.t()) ::
              {:noreply, State.t()} | {:noreply, State.t(), keyword()}

  @doc """
  Returns a list of pub/sub topics this screen should subscribe to.

  Called on mount and navigation. The session diffs against current subscriptions
  and subscribes/unsubscribes as needed.
  """
  @callback subscriptions(params :: map(), session :: map()) :: [term()]

  @doc """
  Produces the view-model map from current assigns.

  The returned map must contain exactly the keys declared in the schema.
  The default implementation passes schema-declared assigns through unchanged.
  """
  @callback render(assigns :: map()) :: map()

  @doc """
  Called when the screen is being shut down.

  `reason` is an atom describing why the screen is terminating:
    * `:shutdown` — the session process is stopping
    * `:navigate` — the user is navigating to a different screen
  """
  @callback terminate(reason :: atom(), state :: State.t()) :: :ok

  @optional_callbacks mount: 3,
                      handle_event: 3,
                      handle_params: 2,
                      handle_info: 2,
                      subscriptions: 2,
                      render: 1,
                      terminate: 2
end
