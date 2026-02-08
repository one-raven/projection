defmodule Projection.TestComponents.StatusBadge do
  use ProjectionUI, :component

  schema do
    field(:label, :string, default: "")
    field(:status, :string, default: "ok")
  end
end

defmodule Projection.TestScreens.Clock do
  use ProjectionUI, :screen

  @timezone_offsets %{
    "UTC" => 0,
    "America/New_York" => -5 * 60 * 60,
    "America/Chicago" => -6 * 60 * 60,
    "America/Denver" => -7 * 60 * 60,
    "America/Los_Angeles" => -8 * 60 * 60
  }
  @max_clock_label_length 24

  schema do
    field(:clock_text, :string, default: "--:--:--")
    field(:clock_running, :bool, default: true)
    field(:clock_timezone, :string, default: "UTC")
    field(:clock_label, :string, default: "Projection Clock")
    field(:clock_label_error, :string, default: "")

    component(:status_badge, Projection.TestComponents.StatusBadge,
      default: %{label: "Running", status: "ok"}
    )
  end

  @impl true
  def mount(params, _session, state) do
    next_state =
      state
      |> maybe_assign_clock_timezone(params)
      |> maybe_assign_clock_text(params)
      |> maybe_assign_clock_label(params)
      |> sync_status_badge()

    {:ok, next_state}
  end

  @impl true
  def subscriptions(params, _session) do
    timezone = Map.get(params, "clock_timezone", schema()[:clock_timezone])
    ["clock.timezone:" <> timezone]
  end

  @impl true
  def handle_event("clock.pause", _params, state) do
    next_state =
      state
      |> assign(:clock_running, false)
      |> sync_status_badge()

    {:noreply, next_state}
  end

  def handle_event("clock.resume", _params, state) do
    next_state =
      state
      |> assign(:clock_running, true)
      |> sync_status_badge()

    {:noreply, next_state}
  end

  def handle_event("clock.set_timezone", payload, state) when is_map(payload) do
    case extract_timezone(payload) do
      {:ok, timezone} ->
        next_state =
          state
          |> assign(:clock_timezone, timezone)
          |> assign(:clock_text, current_clock_text(timezone))

        {:noreply, next_state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_event("clock.commit_label", payload, state) when is_map(payload) do
    case extract_clock_label(payload) do
      {:ok, label} ->
        {:noreply, commit_clock_label(state, label)}

      :error ->
        {:noreply, assign(state, :clock_label_error, "Label must be text.")}
    end
  end

  def handle_event(_event, _params, state), do: {:noreply, state}

  @impl true
  def handle_params(params, state) do
    next_state =
      state
      |> maybe_assign_clock_timezone(params)
      |> maybe_assign_clock_text(params)
      |> maybe_assign_clock_label(params)
      |> sync_status_badge()

    {:noreply, next_state}
  end

  @impl true
  def handle_info(:tick, state) do
    if clock_running?(state) do
      {:noreply, assign(state, :clock_text, current_clock_text(clock_timezone(state)))}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp maybe_assign_clock_text(state, %{"clock_text" => value}) when is_binary(value) do
    assign(state, :clock_text, value)
  end

  defp maybe_assign_clock_text(state, _params), do: state

  defp maybe_assign_clock_timezone(state, %{"clock_timezone" => timezone})
       when is_binary(timezone) do
    if valid_timezone?(timezone) do
      state
      |> assign(:clock_timezone, timezone)
      |> assign(:clock_text, current_clock_text(timezone))
    else
      state
    end
  end

  defp maybe_assign_clock_timezone(state, _params), do: state

  defp maybe_assign_clock_label(state, %{"clock_label" => label}) when is_binary(label) do
    assign(state, :clock_label, label)
  end

  defp maybe_assign_clock_label(state, _params), do: state

  defp clock_running?(state), do: Map.get(state.assigns, :clock_running, true)

  defp sync_status_badge(state) do
    assign(state, :status_badge, status_badge(clock_running?(state)))
  end

  defp status_badge(true), do: %{label: "Running", status: "ok"}
  defp status_badge(false), do: %{label: "Paused", status: "warn"}

  defp clock_timezone(state) do
    Map.get(state.assigns, :clock_timezone, schema()[:clock_timezone])
  end

  defp valid_timezone?(timezone), do: Map.has_key?(@timezone_offsets, timezone)

  defp extract_timezone(%{"timezone" => timezone}) when is_binary(timezone) do
    if valid_timezone?(timezone), do: {:ok, timezone}, else: :error
  end

  defp extract_timezone(%{"arg" => timezone}) when is_binary(timezone) do
    if valid_timezone?(timezone), do: {:ok, timezone}, else: :error
  end

  defp extract_timezone(_payload), do: :error

  defp extract_clock_label(%{"label" => label}) when is_binary(label), do: {:ok, label}
  defp extract_clock_label(%{"arg" => label}) when is_binary(label), do: {:ok, label}
  defp extract_clock_label(_payload), do: :error

  defp commit_clock_label(state, raw_label) when is_binary(raw_label) do
    normalized_label = normalize_clock_label(raw_label)

    cond do
      normalized_label == "" ->
        assign(state, :clock_label_error, "Label cannot be empty.")

      String.length(normalized_label) > @max_clock_label_length ->
        truncated_label =
          normalized_label
          |> String.slice(0, @max_clock_label_length)
          |> String.trim_trailing()

        state
        |> assign(:clock_label, truncated_label)
        |> assign(
          :clock_label_error,
          "Label was truncated to #{@max_clock_label_length} characters."
        )

      true ->
        state
        |> assign(:clock_label, normalized_label)
        |> assign(:clock_label_error, "")
    end
  end

  defp normalize_clock_label(raw_label) when is_binary(raw_label) do
    raw_label
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp current_clock_text(timezone) do
    offset_seconds = Map.get(@timezone_offsets, timezone, 0)

    DateTime.utc_now()
    |> DateTime.add(offset_seconds, :second)
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
  end
end

defmodule Projection.TestScreens.Devices do
  use ProjectionUI, :screen

  schema do
    field(:devices, :id_table,
      columns: [name: :string, status: :string],
      default: %{order: [], by_id: %{}}
    )
  end

  @impl true
  def mount(params, _session, state) do
    total = Map.get(params, "count", 25)
    devices = seed_devices(total)
    {:ok, assign(state, :devices, devices)}
  end

  @impl true
  def subscriptions(_params, _session), do: ["devices"]

  @impl true
  def handle_event("set_status", %{"id" => id} = payload, state) do
    devices = Map.get(state.assigns, :devices, %{order: [], by_id: %{}})
    status = Map.get(payload, "status") || Map.get(payload, "status_text")

    case {status, get_in(devices, [:by_id, id])} do
      {status, %{}} when is_binary(status) ->
        next_devices = put_in(devices, [:by_id, id, :status], status)
        {:noreply, assign(state, :devices, next_devices)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_event(_event, _params, state), do: {:noreply, state}

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp seed_devices(total) when is_integer(total) and total > 0 do
    order = Enum.map(1..total, &"dev-#{&1}")

    by_id =
      Enum.into(order, %{}, fn id ->
        {id, %{name: "Device #{id}", status: "Online"}}
      end)

    %{order: order, by_id: by_id}
  end

  defp seed_devices(_total), do: seed_devices(25)
end

defmodule Projection.TestRouter do
  use Projection.Router.DSL

  screen_session :main do
    screen("/clock", Projection.TestScreens.Clock, :show, as: :clock)
    screen("/devices", Projection.TestScreens.Devices, :index, as: :devices)
  end

  screen_session :admin do
    screen("/admin", Projection.TestScreens.Clock, :index, as: :admin)
  end
end
