defmodule Projection.Session do
  @moduledoc """
  Authoritative per-UI-session process.

  Responsibilities:
  - accept `ready` envelopes
  - respond with `render` envelopes from current VM state
  - keep monotonic `rev`
  - keep stable `sid` for a running session
  - emit periodic `patch` updates from screen state changes
  - optionally run route-aware screen switching via a router built with `Projection.Router.DSL`
  """

  use GenServer

  require Logger

  alias Projection.Patch
  alias Projection.Protocol
  alias Projection.Telemetry
  alias ProjectionUI.HostBridge
  alias ProjectionUI.State

  @event_intent_received [:session, :intent, :received]
  @event_render_complete [:session, :render, :complete]
  @event_patch_sent [:session, :patch, :sent]
  @event_error [:session, :error]

  @typedoc "Internal GenServer state for a running session."
  @type state :: %{
          sid: String.t() | nil,
          rev: non_neg_integer(),
          vm: map(),
          batch_window_ms: non_neg_integer(),
          max_pending_ops: pos_integer(),
          pending_patch_ops: [map()],
          pending_ack: non_neg_integer() | nil,
          patch_flush_ref: {reference(), reference()} | nil,
          tick_ms: pos_integer() | nil,
          tick_ref: reference() | nil,
          host_bridge: GenServer.server() | nil,
          router: module() | nil,
          nav: map() | nil,
          app_title: String.t(),
          app_module: module() | nil,
          app_state: State.t() | nil,
          screen_params: map(),
          screen_session: map(),
          screen_module: module(),
          screen_state: State.t(),
          subscriptions: MapSet.t(term()),
          subscription_hook: (atom(), term() -> any())
        }

  @doc """
  Starts a session process linked to the caller.

  ## Options

    * `:name` — registered process name
    * `:sid` — initial session ID (assigned on first `ready` if `nil`)
    * `:router` — router module built with `Projection.Router.DSL`
    * `:route` — initial route name (defaults to the router's first route)
    * `:screen_module` — required when running without a router
    * `:screen_params` — params passed to `c:ProjectionUI.Screen.mount/3`
    * `:screen_session` — session map passed to `c:ProjectionUI.Screen.mount/3`
    * `:batch_window_ms` — patch batch flush window in milliseconds (default `16`)
    * `:max_pending_ops` — max coalesced ops kept before immediate flush (default `128`)
    * `:tick_ms` — interval for `:tick` messages (nil disables)
    * `:host_bridge` — name or pid of the `ProjectionUI.HostBridge` for outbound envelopes
    * `:subscription_hook` — `(action, topic -> any())` callback for pub/sub

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Sends a UI envelope to the session asynchronously.

  This is the primary entry point used by `ProjectionUI.HostBridge` to forward
  `ready` and `intent` envelopes from the host. Outbound responses (renders,
  patches) are dispatched back through the host bridge.
  """
  @spec handle_ui_envelope(GenServer.server(), map()) :: :ok
  def handle_ui_envelope(session, envelope) when is_map(envelope) do
    GenServer.cast(session, {:ui_envelope, envelope})
  end

  @doc false
  @spec handle_ui_envelope_sync(GenServer.server(), map()) :: {:ok, [map()]}
  def handle_ui_envelope_sync(session, envelope) when is_map(envelope) do
    GenServer.call(session, {:ui_envelope_sync, envelope})
  end

  @doc "Returns the full internal state of the session. Useful for testing and debugging."
  @spec snapshot(GenServer.server()) :: state()
  def snapshot(session), do: GenServer.call(session, :snapshot)

  @impl true
  def init(opts) do
    router = normalize_router(Keyword.get(opts, :router))
    screen_session = normalize_screen_session(Keyword.get(opts, :screen_session, %{}))
    app_title = normalize_app_title(Keyword.get(opts, :app_title, "Projection"))
    subscription_hook = normalize_subscription_hook(Keyword.get(opts, :subscription_hook))
    app_module = resolve_app_module(Keyword.get(opts, :app_module))

    {screen_module, screen_params, screen_state, nav} =
      init_screen_context(opts, router, screen_session)

    app_state = mount_app(app_module)

    state =
      %{
        sid: Keyword.get(opts, :sid),
        rev: 0,
        vm: %{},
        batch_window_ms: normalize_batch_window_ms(Keyword.get(opts, :batch_window_ms, 16)),
        max_pending_ops: normalize_max_pending_ops(Keyword.get(opts, :max_pending_ops, 128)),
        pending_patch_ops: [],
        pending_ack: nil,
        patch_flush_ref: nil,
        tick_ms: normalize_tick_ms(Keyword.get(opts, :tick_ms)),
        tick_ref: nil,
        host_bridge: Keyword.get(opts, :host_bridge),
        router: router,
        nav: nav,
        app_title: app_title,
        app_module: app_module,
        app_state: app_state,
        screen_params: screen_params,
        screen_session: screen_session,
        screen_module: screen_module,
        screen_state: screen_state,
        subscriptions: MapSet.new(),
        subscription_hook: subscription_hook
      }
      |> sync_subscriptions()

    state = %{state | vm: initial_vm(state)}
    put_logger_metadata(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call({:ui_envelope_sync, envelope}, _from, state) do
    put_logger_metadata(state)
    {:ok, outbound, next_state} = process_ui_envelope(envelope, state)
    put_logger_metadata(next_state)
    {:reply, {:ok, outbound}, next_state}
  end

  @impl true
  def handle_cast({:ui_envelope, envelope}, state) do
    put_logger_metadata(state)
    {:ok, outbound, next_state} = process_ui_envelope(envelope, state)
    put_logger_metadata(next_state)
    {:noreply, dispatch_outbound(next_state, outbound)}
  end

  @impl true
  def handle_info(:tick, state) do
    put_logger_metadata(state)
    state = %{state | tick_ref: nil}
    state = dispatch_to_app_state(state, :tick)
    screen_state = dispatch_screen_info(state.screen_module, :tick, state.screen_state)
    next_state = apply_screen_update(state, screen_state, nil)
    put_logger_metadata(next_state)
    {:noreply, maybe_schedule_tick(next_state)}
  end

  def handle_info({:flush_patch_batch, token}, %{patch_flush_ref: {token, _timer_ref}} = state) do
    put_logger_metadata(state)
    state = %{state | patch_flush_ref: nil}
    next_state = flush_pending_patch_batch(state)
    put_logger_metadata(next_state)
    {:noreply, next_state}
  end

  def handle_info({:flush_patch_batch, _token}, state) do
    put_logger_metadata(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    put_logger_metadata(state)
    state = dispatch_to_app_state(state, message)
    screen_state = dispatch_screen_info(state.screen_module, message, state.screen_state)
    next_state = apply_screen_update(state, screen_state, nil)
    put_logger_metadata(next_state)
    {:noreply, next_state}
  end

  @impl true
  def terminate(_reason, state) do
    put_logger_metadata(state)
    cancel_patch_flush_timer(state.patch_flush_ref)

    state
    |> Map.get(:subscriptions, MapSet.new())
    |> Enum.each(fn topic -> dispatch_subscription(state, :unsubscribe, topic) end)

    :ok
  end

  defp process_ui_envelope(envelope, state) do
    case envelope do
      %{"t" => "ready", "sid" => incoming_sid} when is_binary(incoming_sid) ->
        state = clear_pending_patch_batch(state)
        sid = ensure_stable_sid(state.sid, incoming_sid)
        rev = state.rev + 1
        next_state = maybe_schedule_tick(%{state | sid: sid, rev: rev})
        put_logger_metadata(next_state)
        Logger.info("ui ready received; sending render snapshot")
        render = Protocol.render_envelope(sid, rev, state.vm)
        {:ok, [render], next_state}

      %{"t" => "intent", "name" => name} = intent when is_binary(name) ->
        payload = normalize_payload(Map.get(intent, "payload"))
        ack = normalize_ack(Map.get(intent, "id"))
        emit_intent_received(state, name, ack)
        Logger.debug("ui intent received name=#{name} ack=#{inspect(ack)}")

        case maybe_handle_route_intent(name, payload, ack, state) do
          {:handled, next_state} ->
            {:ok, [], next_state}

          :unhandled ->
            screen_state =
              dispatch_screen_event(state.screen_module, name, payload, state.screen_state)

            next_state = apply_screen_update(state, screen_state, ack)
            {:ok, [], next_state}
        end

      _ ->
        {:ok, [], state}
    end
  end

  defp maybe_handle_route_intent(_name, _payload, _ack, %{router: nil}), do: :unhandled

  defp maybe_handle_route_intent("ui.route.navigate", payload, ack, state) do
    {:handled, apply_route_navigate(state, payload, ack)}
  end

  defp maybe_handle_route_intent("ui.route.patch", payload, ack, state) do
    {:handled, apply_route_patch(state, payload, ack)}
  end

  defp maybe_handle_route_intent("ui.back", _payload, ack, state) do
    {:handled, apply_route_back(state, ack)}
  end

  defp maybe_handle_route_intent(_name, _payload, _ack, _state), do: :unhandled

  defp apply_route_navigate(state, payload, ack) do
    from_screen = session_screen_label(state)
    to_name = Map.get(payload, "to") || Map.get(payload, "arg")
    params = normalize_screen_params(Map.get(payload, "params", %{}))

    with true <- is_binary(to_name),
         {:ok, false} <- state.router.screen_session_transition?(state.nav, to_name),
         {:ok, nav} <- state.router.navigate(state.nav, to_name, params),
         {:ok, route_def} <- state.router.current_route(nav) do
      screen_state = mount_screen!(route_def.screen_module, params, state.screen_session)

      state
      |> Map.merge(%{
        nav: nav,
        screen_module: route_def.screen_module,
        screen_params: params
      })
      |> tap(fn _ ->
        Logger.info("screen transition navigate from=#{from_screen} to=#{to_name}")
      end)
      |> sync_subscriptions()
      |> apply_screen_update(screen_state, ack)
    else
      {:ok, true} ->
        Logger.warning("blocked cross screen_session navigation to #{inspect(to_name)}")
        state

      _ ->
        state
    end
  end

  defp apply_route_patch(state, payload, ack) do
    params_patch = normalize_screen_params(Map.get(payload, "params", %{}))
    nav = state.router.patch(state.nav, params_patch)
    current = state.router.current(nav)

    with {:ok, route_def} <- state.router.current_route(nav) do
      screen_state =
        dispatch_screen_params(
          route_def.screen_module,
          current.params,
          state.screen_state,
          state.screen_session
        )

      state
      |> Map.merge(%{
        nav: nav,
        screen_module: route_def.screen_module,
        screen_params: current.params
      })
      |> sync_subscriptions()
      |> apply_screen_update(screen_state, ack)
    else
      _ -> state
    end
  end

  defp apply_route_back(state, ack) do
    from_screen = session_screen_label(state)

    with {:ok, nav} <- state.router.back(state.nav),
         {:ok, route_def} <- state.router.current_route(nav) do
      current = state.router.current(nav)
      screen_state = mount_screen!(route_def.screen_module, current.params, state.screen_session)

      state
      |> Map.merge(%{
        nav: nav,
        screen_module: route_def.screen_module,
        screen_params: current.params
      })
      |> tap(fn _ ->
        Logger.info("screen transition back from=#{from_screen} to=#{current.name}")
      end)
      |> sync_subscriptions()
      |> apply_screen_update(screen_state, ack)
    else
      _ -> state
    end
  end

  defp init_screen_context(opts, nil, screen_session) do
    screen_params = normalize_screen_params(Keyword.get(opts, :screen_params, %{}))
    screen_module = Keyword.fetch!(opts, :screen_module)
    screen_state = mount_screen!(screen_module, screen_params, screen_session)
    {screen_module, screen_params, screen_state, nil}
  end

  defp init_screen_context(opts, router, screen_session) do
    route_name = normalize_route_name(Keyword.get(opts, :route), router)
    screen_params = normalize_screen_params(Keyword.get(opts, :screen_params, %{}))

    with {:ok, nav} <- router.initial_nav(route_name, screen_params),
         {:ok, route_def} <- router.current_route(nav) do
      screen_state = mount_screen!(route_def.screen_module, screen_params, screen_session)
      {route_def.screen_module, screen_params, screen_state, nav}
    else
      {:error, reason} ->
        raise ArgumentError, "invalid initial route #{inspect(route_name)}: #{inspect(reason)}"
    end
  end

  defp ensure_stable_sid(nil, incoming_sid), do: incoming_sid
  defp ensure_stable_sid(existing_sid, _incoming_sid), do: existing_sid

  defp mount_screen!(screen_module, params, session) do
    initial_state = State.new(screen_module.schema())

    if function_exported?(screen_module, :mount, 3) do
      case screen_module.mount(params, session, initial_state) do
        {:ok, %State{} = state} ->
          state

        other ->
          raise "invalid mount response from #{inspect(screen_module)}: #{inspect(other)}"
      end
    else
      initial_state
    end
  end

  defp resolve_app_module(nil) do
    Application.get_env(:projection, :app_module)
  end

  defp resolve_app_module(module) when is_atom(module), do: module

  defp mount_app(nil), do: nil

  defp mount_app(app_module) do
    initial_state = State.new(app_module.schema())

    case app_module.mount(initial_state) do
      {:ok, %State{} = state} ->
        State.clear_changed(state)

      other ->
        raise "invalid mount response from app state #{inspect(app_module)}: #{inspect(other)}"
    end
  end

  defp dispatch_to_app_state(%{app_module: nil} = state, _message), do: state

  defp dispatch_to_app_state(%{app_module: mod, app_state: app_state} = state, message) do
    case mod.handle_info(message, app_state) do
      {:noreply, %State{} = next} ->
        %{state | app_state: State.clear_changed(next)}

      other ->
        Logger.warning(
          "invalid handle_info response from app state #{inspect(mod)}: #{inspect(other)}"
        )

        state
    end
  end

  defp dispatch_screen_event(screen_module, event, payload, %State{} = state) do
    if function_exported?(screen_module, :handle_event, 3) do
      case screen_module.handle_event(event, payload, state) do
        {:noreply, %State{} = next_state} ->
          next_state

        other ->
          Logger.warning(
            "invalid handle_event response from #{inspect(screen_module)}: #{inspect(other)}"
          )

          state
      end
    else
      state
    end
  end

  defp dispatch_screen_params(screen_module, params, %State{} = state, session) do
    if function_exported?(screen_module, :handle_params, 2) do
      case screen_module.handle_params(params, state) do
        {:noreply, %State{} = next_state} ->
          next_state

        other ->
          Logger.warning(
            "invalid handle_params response from #{inspect(screen_module)}: #{inspect(other)}"
          )

          state
      end
    else
      mount_screen!(screen_module, params, session)
    end
  end

  defp dispatch_screen_info(screen_module, message, %State{} = state) do
    if function_exported?(screen_module, :handle_info, 2) do
      case screen_module.handle_info(message, state) do
        {:noreply, %State{} = next_state} ->
          next_state

        other ->
          Logger.warning(
            "invalid handle_info response from #{inspect(screen_module)}: #{inspect(other)}"
          )

          state
      end
    else
      state
    end
  end

  defp initial_vm(state) do
    {_status, vm} = render_vm_with_status(state)
    vm
  end

  defp render_vm_with_status(%{router: nil} = state) do
    render_started = System.monotonic_time()

    result =
      case safe_render_screen(state.screen_module, state.screen_state.assigns, state) do
        {:ok, vm} ->
          {:ok, vm}

        {:error, error_vm} ->
          {:error, render_error_vm(state, error_vm)}
      end

    emit_render_complete(state, result, render_started)
    result
  end

  defp render_vm_with_status(state) do
    current = state.router.current(state.nav)
    render_started = System.monotonic_time()

    result =
      case safe_render_screen(state.screen_module, state.screen_state.assigns, state) do
        {:ok, screen_vm} ->
          {:ok,
           %{
             app: build_app_vm(state),
             nav: state.router.to_vm(state.nav),
             screen: %{
               name: current.name,
               action: current.action,
               vm: screen_vm
             }
           }}

        {:error, error_vm} ->
          {:error, render_error_vm(state, error_vm)}
      end

    emit_render_complete(state, result, render_started)
    result
  end

  defp safe_render_screen(screen_module, assigns, context_state) when is_map(assigns) do
    try do
      vm = render_screen(screen_module, assigns)

      if is_map(vm) do
        {:ok, vm}
      else
        raise "render/1 must return a map, got: #{inspect(vm)}"
      end
    rescue
      exception ->
        stacktrace = __STACKTRACE__

        metadata =
          telemetry_metadata(context_state, %{
            kind: :render_exception,
            error: Exception.message(exception),
            exception: inspect(exception)
          })

        Telemetry.execute(@event_error, %{count: 1}, metadata)

        Logger.error(
          "screen render failed for #{inspect(screen_module)}\n" <>
            Exception.format(:error, exception, stacktrace)
        )

        {:error,
         %{
           title: "Rendering Error",
           message: Exception.message(exception),
           screen_module: inspect(screen_module)
         }}
    end
  end

  defp render_screen(screen_module, assigns) when is_map(assigns) do
    if function_exported?(screen_module, :render, 1) do
      screen_module.render(assigns)
    else
      defaults = screen_module.schema()

      if map_size(defaults) == 0 do
        assigns
      else
        defaults
        |> Map.merge(Map.take(assigns, Map.keys(defaults)))
      end
    end
  end

  defp build_app_vm(%{app_module: nil} = state), do: %{title: state.app_title}

  defp build_app_vm(%{app_module: mod, app_state: %State{assigns: assigns}} = state) do
    defaults = mod.schema()

    app_assigns =
      if map_size(defaults) == 0 do
        assigns
      else
        Map.merge(defaults, Map.take(assigns, Map.keys(defaults)))
      end

    Map.merge(%{title: state.app_title}, app_assigns)
  end

  defp render_error_vm(state, error_vm) do
    nav_vm =
      if state.router && state.nav do
        state.router.to_vm(state.nav)
      else
        %{stack: []}
      end

    %{
      app: build_app_vm(state),
      nav: nav_vm,
      screen: %{
        name: "error",
        action: "render_error",
        vm: error_vm
      }
    }
  end

  defp apply_screen_update(state, %State{} = screen_state, ack) do
    changed_fields = State.changed_fields(screen_state)
    next_state = %{state | screen_state: State.clear_changed(screen_state)}
    {render_status, next_vm} = render_vm_with_status(next_state)

    ops =
      case render_status do
        :ok -> vm_patch_ops(state.vm, next_vm, changed_fields, next_state.router)
        :error -> vm_patch_ops(state.vm, next_vm)
      end

    next_state = %{next_state | vm: next_vm}

    case {state.sid, ops} do
      {_sid, []} ->
        next_state

      {nil, _ops} ->
        next_state

      {_sid, _ops} ->
        enqueue_patch_batch(next_state, ops, ack)
    end
  end

  defp vm_patch_ops(previous_vm, next_vm, _changed_fields, _router) when previous_vm == next_vm do
    []
  end

  defp vm_patch_ops(previous_vm, next_vm, [], _router) do
    vm_patch_ops(previous_vm, next_vm)
  end

  defp vm_patch_ops(previous_vm, next_vm, changed_fields, nil) do
    changed_fields
    |> Enum.map(&[to_string(&1)])
    |> Enum.flat_map(&diff_at_path(previous_vm, next_vm, &1))
  end

  defp vm_patch_ops(previous_vm, next_vm, changed_fields, _router) do
    global_paths = [
      ["app"],
      ["nav"],
      ["screen", "name"],
      ["screen", "action"]
    ]

    screen_vm_paths =
      if screen_identity_changed?(previous_vm, next_vm) do
        [["screen", "vm"]]
      else
        changed_fields
        |> Enum.map(&to_string/1)
        |> Enum.sort()
        |> Enum.map(&["screen", "vm", &1])
      end

    (global_paths ++ screen_vm_paths)
    |> Enum.flat_map(&diff_at_path(previous_vm, next_vm, &1))
  end

  defp vm_patch_ops(previous_vm, next_vm) when is_map(previous_vm) and is_map(next_vm) do
    diff_map(previous_vm, next_vm, [])
  end

  defp diff_at_path(previous_vm, next_vm, path_tokens) when is_list(path_tokens) do
    path = Patch.pointer(path_tokens)

    case {path_value(previous_vm, path_tokens), path_value(next_vm, path_tokens)} do
      {{:ok, previous_value}, {:ok, current_value}} ->
        diff_value(previous_value, current_value, path_tokens)

      {:error, {:ok, current_value}} ->
        [Patch.add(path, current_value)]

      {{:ok, _previous_value}, :error} ->
        [Patch.remove(path)]

      {:error, :error} ->
        []
    end
  end

  defp screen_identity_changed?(previous_vm, next_vm) do
    path_value(previous_vm, ["screen", "name"]) != path_value(next_vm, ["screen", "name"]) or
      path_value(previous_vm, ["screen", "action"]) !=
        path_value(next_vm, ["screen", "action"])
  end

  defp path_value(value, []), do: {:ok, value}

  defp path_value(%{} = map, [token | rest]) do
    with {:ok, key} <- resolve_map_key(map, token),
         {:ok, child} <- Map.fetch(map, key) do
      path_value(child, rest)
    else
      :error -> :error
    end
  end

  defp path_value(_value, _tokens), do: :error

  defp resolve_map_key(map, token) when is_binary(token) do
    cond do
      Map.has_key?(map, token) ->
        {:ok, token}

      true ->
        case maybe_existing_atom(token) do
          {:ok, atom_key} ->
            if Map.has_key?(map, atom_key), do: {:ok, atom_key}, else: :error

          _ ->
            :error
        end
    end
  end

  defp maybe_existing_atom(token) when is_binary(token) do
    try do
      {:ok, String.to_existing_atom(token)}
    rescue
      ArgumentError -> :error
    end
  end

  defp diff_map(previous, current, tokens) when is_map(previous) and is_map(current) do
    previous
    |> Map.keys()
    |> Kernel.++(Map.keys(current))
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
    |> Enum.flat_map(fn key ->
      key_tokens = tokens ++ [to_string(key)]
      previous_has_key? = Map.has_key?(previous, key)
      current_has_key? = Map.has_key?(current, key)

      cond do
        previous_has_key? and current_has_key? ->
          previous_value = Map.fetch!(previous, key)
          current_value = Map.fetch!(current, key)
          diff_value(previous_value, current_value, key_tokens)

        current_has_key? ->
          [Patch.add(Patch.pointer(key_tokens), Map.fetch!(current, key))]

        true ->
          [Patch.remove(Patch.pointer(key_tokens))]
      end
    end)
  end

  defp diff_value(previous, current, tokens) when is_map(previous) and is_map(current) do
    if previous == current do
      []
    else
      diff_map(previous, current, tokens)
    end
  end

  defp diff_value(previous, current, tokens) do
    if previous == current do
      []
    else
      [Patch.replace(Patch.pointer(tokens), current)]
    end
  end

  defp sync_subscriptions(state) do
    desired = desired_subscriptions(state)
    current = Map.get(state, :subscriptions, MapSet.new())

    unsubscribe_topics = MapSet.difference(current, desired)
    subscribe_topics = MapSet.difference(desired, current)

    Enum.each(unsubscribe_topics, fn topic ->
      dispatch_subscription(state, :unsubscribe, topic)
    end)

    Enum.each(subscribe_topics, fn topic ->
      dispatch_subscription(state, :subscribe, topic)
    end)

    %{state | subscriptions: desired}
  end

  defp desired_subscriptions(%{
         screen_module: screen_module,
         screen_params: screen_params,
         screen_session: screen_session
       }) do
    if function_exported?(screen_module, :subscriptions, 2) do
      screen_module.subscriptions(screen_params, screen_session)
      |> normalize_subscriptions()
    else
      MapSet.new()
    end
  end

  defp normalize_subscriptions(topics) when is_list(topics), do: MapSet.new(topics)
  defp normalize_subscriptions(_topics), do: MapSet.new()

  defp dispatch_subscription(state, action, topic) do
    try do
      state.subscription_hook.(action, topic)
    rescue
      error ->
        Logger.warning(
          "subscription hook failed for #{action} #{inspect(topic)}: #{inspect(error)}"
        )
    end
  end

  defp normalize_ack(ack) when is_integer(ack), do: ack
  defp normalize_ack(_ack), do: nil

  defp normalize_payload(payload) when is_map(payload), do: payload
  defp normalize_payload(_payload), do: %{}

  defp normalize_screen_params(params) when is_map(params), do: params
  defp normalize_screen_params(_params), do: %{}

  defp normalize_router(nil), do: nil
  defp normalize_router(router) when is_atom(router), do: router
  defp normalize_router(_router), do: nil

  defp normalize_route_name(name, _router) when is_binary(name), do: name
  defp normalize_route_name(name, _router) when is_atom(name), do: Atom.to_string(name)

  defp normalize_route_name(_name, router) when is_atom(router) do
    if function_exported?(router, :default_route_name, 0) do
      router.default_route_name()
    else
      raise ArgumentError,
            "router #{inspect(router)} must export default_route_name/0 when :route is not provided"
    end
  end

  defp normalize_app_title(title) when is_binary(title) and title != "", do: title
  defp normalize_app_title(_title), do: "Projection"

  defp dispatch_outbound(%{host_bridge: nil} = state, _envelopes), do: state

  defp dispatch_outbound(%{host_bridge: host_bridge} = state, envelopes) do
    if GenServer.whereis(host_bridge) do
      Enum.each(envelopes, fn envelope ->
        HostBridge.send_envelope(host_bridge, envelope)
      end)
    end

    state
  end

  defp maybe_schedule_tick(%{tick_ms: nil} = state), do: state

  defp maybe_schedule_tick(%{tick_ms: _tick_ms, tick_ref: tick_ref} = state)
       when is_reference(tick_ref),
       do: state

  defp maybe_schedule_tick(%{tick_ms: tick_ms} = state) do
    ref = Process.send_after(self(), :tick, tick_ms)
    %{state | tick_ref: ref}
  end

  defp enqueue_patch_batch(state, ops, ack) when is_list(ops) do
    pending_ops = coalesce_patch_ops(state.pending_patch_ops ++ ops)
    pending_ack = merge_patch_ack(state.pending_ack, ack)
    next_state = %{state | pending_patch_ops: pending_ops, pending_ack: pending_ack}

    cond do
      pending_ops == [] ->
        clear_pending_patch_batch(next_state)

      next_state.batch_window_ms == 0 ->
        flush_pending_patch_batch(next_state)

      length(pending_ops) >= next_state.max_pending_ops ->
        flush_pending_patch_batch(next_state)

      true ->
        schedule_patch_batch_flush(next_state)
    end
  end

  defp flush_pending_patch_batch(%{pending_patch_ops: []} = state) do
    clear_pending_patch_batch(state)
  end

  defp flush_pending_patch_batch(%{sid: nil} = state) do
    clear_pending_patch_batch(state)
  end

  defp flush_pending_patch_batch(%{sid: sid} = state) when is_binary(sid) do
    ops_count = length(state.pending_patch_ops)
    rev = state.rev + 1
    patch_opts = if is_nil(state.pending_ack), do: [], else: [ack: state.pending_ack]
    patch = Protocol.patch_envelope(sid, rev, state.pending_patch_ops, patch_opts)

    next_state =
      state
      |> clear_pending_patch_batch()
      |> Map.put(:rev, rev)

    put_logger_metadata(next_state)
    Logger.debug("patch sent rev=#{rev} ops=#{ops_count} ack=#{inspect(state.pending_ack)}")

    Telemetry.execute(
      @event_patch_sent,
      %{count: 1, op_count: ops_count},
      telemetry_metadata(next_state, %{ack: state.pending_ack})
    )

    dispatch_outbound(next_state, [patch])
  end

  defp schedule_patch_batch_flush(
         %{patch_flush_ref: nil, batch_window_ms: batch_window_ms} = state
       ) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:flush_patch_batch, token}, batch_window_ms)
    %{state | patch_flush_ref: {token, timer_ref}}
  end

  defp schedule_patch_batch_flush(state), do: state

  defp clear_pending_patch_batch(state) do
    cancel_patch_flush_timer(state.patch_flush_ref)
    %{state | pending_patch_ops: [], pending_ack: nil, patch_flush_ref: nil}
  end

  defp cancel_patch_flush_timer({_token, timer_ref}) when is_reference(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_patch_flush_timer(_ref), do: :ok

  defp coalesce_patch_ops(ops) when is_list(ops) do
    {paths, _seen, latest_by_path} =
      Enum.reduce(ops, {[], MapSet.new(), %{}}, fn op, {paths, seen, latest_by_path} ->
        case patch_op_path(op) do
          path when is_binary(path) ->
            next_paths = if MapSet.member?(seen, path), do: paths, else: [path | paths]
            next_seen = MapSet.put(seen, path)
            next_latest_by_path = Map.put(latest_by_path, path, op)
            {next_paths, next_seen, next_latest_by_path}

          _ ->
            {paths, seen, latest_by_path}
        end
      end)

    paths
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(latest_by_path, &1))
  end

  defp patch_op_path(%{"path" => path}) when is_binary(path), do: path
  defp patch_op_path(_op), do: nil

  defp merge_patch_ack(nil, nil), do: nil
  defp merge_patch_ack(ack, nil), do: ack
  defp merge_patch_ack(nil, ack), do: ack
  defp merge_patch_ack(left, right), do: max(left, right)

  defp normalize_tick_ms(tick_ms) when is_integer(tick_ms) and tick_ms > 0, do: tick_ms
  defp normalize_tick_ms(_tick_ms), do: nil

  defp normalize_batch_window_ms(ms) when is_integer(ms) and ms >= 0, do: ms
  defp normalize_batch_window_ms(_ms), do: 16

  defp normalize_max_pending_ops(max_pending_ops)
       when is_integer(max_pending_ops) and max_pending_ops > 0,
       do: max_pending_ops

  defp normalize_max_pending_ops(_max_pending_ops), do: 128

  defp normalize_screen_session(session) when is_map(session), do: session

  defp normalize_screen_session(other) do
    raise ArgumentError, "expected :screen_session to be a map, got: #{inspect(other)}"
  end

  defp normalize_subscription_hook(nil), do: fn _action, _topic -> :ok end
  defp normalize_subscription_hook(fun) when is_function(fun, 2), do: fun

  defp normalize_subscription_hook(other) do
    raise ArgumentError,
          "expected :subscription_hook to be a 2-arity function, got: #{inspect(other)}"
  end

  defp emit_intent_received(state, name, ack) do
    Telemetry.execute(
      @event_intent_received,
      %{count: 1},
      telemetry_metadata(state, %{intent: name, ack: ack})
    )
  end

  defp emit_render_complete(state, result, render_started) do
    duration_native = System.monotonic_time() - render_started
    status = if match?({:ok, _}, result), do: :ok, else: :error

    Telemetry.execute(
      @event_render_complete,
      %{count: 1, duration_native: duration_native},
      telemetry_metadata(state, %{status: status})
    )
  end

  defp put_logger_metadata(state) when is_map(state) do
    Logger.metadata(
      sid: Map.get(state, :sid),
      rev: Map.get(state, :rev),
      screen: session_screen_label(state)
    )
  end

  defp session_screen_label(%{router: nil, screen_module: screen_module}) do
    inspect(screen_module)
  end

  defp session_screen_label(%{router: router, nav: nav, screen_module: fallback})
       when is_atom(router) do
    case router.current(nav) do
      %{name: name} when is_binary(name) -> name
      _ -> inspect(fallback)
    end
  rescue
    _ -> inspect(fallback)
  end

  defp session_screen_label(%{screen_module: screen_module}), do: inspect(screen_module)

  defp telemetry_metadata(state, extra) do
    %{
      sid: Map.get(state, :sid),
      rev: Map.get(state, :rev),
      screen: session_screen_label(state)
    }
    |> Map.merge(extra)
  end
end
