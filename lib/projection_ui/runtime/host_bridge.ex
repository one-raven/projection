defmodule ProjectionUI.HostBridge do
  @moduledoc """
  Owns the external UI host port process and forwards envelopes between
  the host and `Projection.Session`.

  M1 behavior:
  - decode inbound JSON envelopes from the port
  - forward to `Projection.Session`
  - encode outbound envelopes back to the port
  - reconnect using bounded exponential backoff
  """

  use GenServer

  require Logger

  alias Projection.Session
  alias Projection.Protocol
  alias Projection.Telemetry

  @backoff_steps_ms [100, 200, 500, 1_000, 2_000, 5_000]
  @event_error [:host_bridge, :error]
  @min_stable_ms 2_000

  @typedoc "Internal state for the port owner process."
  @type state :: %{
          session: GenServer.server(),
          sid: String.t(),
          port: port() | nil,
          command: String.t() | nil,
          args: [String.t()],
          env: [{String.t(), String.t()}],
          cd: String.t(),
          stderr_to_stdout: boolean(),
          reconnect_idx: non_neg_integer(),
          connected_at: integer() | nil
        }

  @doc """
  Starts the port owner linked to the caller.

  ## Options

    * `:name` — registered process name
    * `:session` — (required) name or pid of the `Projection.Session` to forward envelopes to
    * `:command` — path to the UI host executable (nil keeps the port disconnected)
    * `:args` — command-line arguments for the host binary
    * `:env` — list of `{key, value}` environment variable tuples
    * `:cd` — working directory for the host process
    * `:stderr_to_stdout` — when `true`, merges host stderr into the framed protocol stream
      (default: `false`)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Sends an outbound envelope to the UI host port. Silently drops if the port is down."
  @spec send_envelope(GenServer.server(), map()) :: :ok
  def send_envelope(server, envelope) when is_map(envelope) do
    GenServer.cast(server, {:send_envelope, envelope})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      session: Keyword.fetch!(opts, :session),
      sid: normalize_sid(Keyword.get(opts, :sid, "S1")),
      port: nil,
      command: Keyword.get(opts, :command),
      args: Keyword.get(opts, :args, []),
      env: Keyword.get(opts, :env, []),
      cd: Keyword.get(opts, :cd, File.cwd!()),
      stderr_to_stdout: Keyword.get(opts, :stderr_to_stdout, false),
      reconnect_idx: 0,
      connected_at: nil
    }

    state = maybe_connect(state)
    put_logger_metadata(state)
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_envelope, envelope}, state) do
    put_logger_metadata(state)
    next_state = dispatch_to_port(envelope, state)
    put_logger_metadata(next_state)
    {:noreply, next_state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    put_logger_metadata(state)
    next_state = maybe_connect(state)
    put_logger_metadata(next_state)
    {:noreply, next_state}
  end

  def handle_info({port, {:data, payload}}, %{port: port} = state) when is_binary(payload) do
    put_logger_metadata(state)

    next_state =
      case Protocol.decode_inbound(payload) do
        {:ok, envelope} ->
          next_state = maybe_track_sid_from_envelope(envelope, state)
          put_logger_metadata(next_state)
          Session.handle_ui_envelope(state.session, envelope)
          next_state

        {:error, reason} ->
          Logger.warning("ui_host inbound decode failed: #{inspect(reason)}")
          emit_error(reason, state, %{source: :decode_inbound})
          handle_decode_error(reason, state)
      end

    put_logger_metadata(next_state)
    {:noreply, next_state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    put_logger_metadata(state)
    close_port(port)
    state = reset_backoff_if_stable(%{state | port: nil, connected_at: nil})
    Logger.warning("ui_host exited with status #{status}; scheduling reconnect")
    emit_error(:port_exit_status, state, %{status: status})
    {:noreply, schedule_reconnect(state)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    put_logger_metadata(state)
    close_port(port)
    state = reset_backoff_if_stable(%{state | port: nil, connected_at: nil})
    Logger.warning("ui_host port exit #{inspect(reason)}; scheduling reconnect")
    emit_error(:port_exit, state, %{reason: inspect(reason)})
    {:noreply, schedule_reconnect(state)}
  end

  def handle_info(_msg, state) do
    put_logger_metadata(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    close_port(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp close_port(port) when is_port(port) do
    try do
      Port.close(port)
    catch
      :error, _ -> :ok
    end
  end

  defp close_port(_), do: :ok

  defp dispatch_to_port(envelope, %{port: nil} = state) do
    maybe_track_sid_from_envelope(envelope, state)
  end

  defp dispatch_to_port(envelope, %{port: port} = state) do
    case Protocol.encode_outbound(envelope) do
      {:ok, payload} ->
        try do
          Port.command(port, payload)
        rescue
          ArgumentError ->
            Logger.warning("ui_host port closed during send; scheduling reconnect")
            emit_error(:port_closed_during_send, state, %{source: :encode_outbound})
        end

        maybe_track_sid_from_envelope(envelope, state)

      {:error, reason} ->
        Logger.warning("ui_host outbound encode failed: #{inspect(reason)}")
        emit_error(reason, state, %{source: :encode_outbound})
        state
    end
  end

  defp maybe_connect(%{command: nil} = state) do
    Logger.debug("ProjectionUI.HostBridge started without :command; port remains disconnected")
    state
  end

  defp maybe_connect(state) do
    try do
      port =
        Port.open(
          {:spawn_executable, state.command},
          [
            :binary,
            {:packet, 4},
            :exit_status,
            :use_stdio
          ]
          |> maybe_include_stderr_to_stdout(state.stderr_to_stdout)
          |> Kernel.++(
            args: state.args,
            env: normalize_env(state.env),
            cd: state.cd
          )
        )

      Logger.info(
        "ui_host port started command=#{state.command} args=#{inspect(state.args)} cd=#{state.cd}"
      )

      %{state | port: port, connected_at: System.monotonic_time(:millisecond)}
    rescue
      error ->
        Logger.warning("failed to start ui_host: #{Exception.message(error)}")
        emit_error(:connect_failed, state, %{error: Exception.message(error)})
        schedule_reconnect(state)
    end
  end

  defp reset_backoff_if_stable(%{connected_at: nil} = state), do: state

  defp reset_backoff_if_stable(%{connected_at: connected_at} = state) do
    uptime = System.monotonic_time(:millisecond) - connected_at

    if uptime >= @min_stable_ms do
      %{state | reconnect_idx: 0}
    else
      state
    end
  end

  defp schedule_reconnect(%{command: nil} = state), do: state

  defp schedule_reconnect(state) do
    idx = min(state.reconnect_idx, length(@backoff_steps_ms) - 1)
    base = Enum.at(@backoff_steps_ms, idx)
    jitter = :rand.uniform(max(div(base, 10), 1)) - 1
    delay = base + jitter

    Process.send_after(self(), :reconnect, delay)

    %{state | reconnect_idx: min(idx + 1, length(@backoff_steps_ms) - 1)}
  end

  defp normalize_env(env) do
    Enum.map(env, fn {key, value} ->
      {to_charlist(key), to_charlist(value)}
    end)
  end

  defp maybe_include_stderr_to_stdout(port_opts, true), do: [:stderr_to_stdout | port_opts]
  defp maybe_include_stderr_to_stdout(port_opts, _), do: port_opts

  defp handle_decode_error(reason, state) do
    {code, message} = decode_error_details(reason)

    state = dispatch_to_port(Protocol.error_envelope(state.sid, nil, code, message), state)

    Session.handle_ui_envelope(state.session, %{"t" => "ready", "sid" => state.sid})
    state
  end

  defp decode_error_details(:frame_too_large),
    do: {"frame_too_large", "inbound frame exceeds ui_to_elixir cap"}

  defp decode_error_details(:decode_error),
    do: {"decode_error", "malformed inbound json payload"}

  defp decode_error_details(:invalid_envelope),
    do: {"invalid_envelope", "inbound payload must decode to a json object"}

  defp decode_error_details(other),
    do: {"decode_error", "inbound decode failed: #{inspect(other)}"}

  defp maybe_track_sid_from_envelope(%{"sid" => sid}, state) when is_binary(sid) and sid != "" do
    %{state | sid: sid}
  end

  defp maybe_track_sid_from_envelope(_envelope, state), do: state

  defp normalize_sid(sid) when is_binary(sid) and sid != "", do: sid
  defp normalize_sid(_sid), do: "S1"

  defp put_logger_metadata(state) when is_map(state) do
    Logger.metadata(sid: state.sid, rev: nil, screen: "host_bridge")
  end

  defp emit_error(reason, state, extra) do
    Telemetry.execute(
      @event_error,
      %{count: 1},
      Map.merge(
        %{
          sid: state.sid,
          rev: nil,
          screen: "host_bridge",
          code: to_string(reason)
        },
        Map.new(extra)
      )
    )
  end
end
