defmodule ProjectionUI.SessionSupervisor do
  @moduledoc """
  Supervises one authoritative `Projection.Session` and its `ProjectionUI.HostBridge`.

  Strategy is `:rest_for_one` to ensure port restarts follow session restarts.
  """

  use Supervisor

  @doc """
  Starts the supervisor with a `Projection.Session` and `ProjectionUI.HostBridge`
  child pair.

  Accepts all options supported by `Projection.Session.start_link/1` and
  `ProjectionUI.HostBridge.start_link/1`, plus:

    * `:name` — supervisor name
    * `:session_name` — registered name for the session (default: `Projection.Session`)
    * `:host_bridge_name` — registered name for the bridge (default: `ProjectionUI.HostBridge`)
    * `:command` — path to the UI host executable
    * `:stderr_to_stdout` — whether to merge host stderr into the protocol stream

  You must provide either `:router` or `:screen_module`.

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    session_name = Keyword.get(opts, :session_name, Projection.Session)
    host_bridge_name = Keyword.get(opts, :host_bridge_name, ProjectionUI.HostBridge)

    router = Keyword.get(opts, :router)
    route = Keyword.get(opts, :route)
    screen_module = Keyword.get(opts, :screen_module)
    screen_params = Keyword.get(opts, :screen_params)
    screen_session = Keyword.get(opts, :screen_session)
    subscription_hook = Keyword.get(opts, :subscription_hook)
    validate_screen_runtime!(router, screen_module)

    session_opts =
      [
        name: session_name,
        sid: Keyword.get(opts, :sid),
        tick_ms: Keyword.get(opts, :tick_ms),
        host_bridge: host_bridge_name
      ]
      |> maybe_put(:router, router)
      |> maybe_put(:route, route)
      |> maybe_put(:screen_module, screen_module)
      |> maybe_put(:screen_params, screen_params)
      |> maybe_put(:screen_session, screen_session)
      |> maybe_put(:subscription_hook, subscription_hook)

    children = [
      {Projection.Session, session_opts},
      {ProjectionUI.HostBridge,
       [
         name: host_bridge_name,
         session: session_name,
         sid: Keyword.get(opts, :sid, "S1"),
         command: Keyword.get(opts, :command),
         args: Keyword.get(opts, :args, []),
         env: Keyword.get(opts, :env, []),
         cd: Keyword.get(opts, :cd, File.cwd!()),
         stderr_to_stdout: Keyword.get(opts, :stderr_to_stdout, false)
       ]}
    ]

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 5,
      max_seconds: 30
    )
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp validate_screen_runtime!(nil, nil) do
    raise ArgumentError,
          "start_link/1 requires either :router or :screen_module to build a session runtime"
  end

  defp validate_screen_runtime!(_router, _screen_module), do: :ok
end
