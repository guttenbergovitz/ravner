defmodule Ravner.Telemetry.EventBuffer do
  @moduledoc """
  In-memory circular ring buffer for recent synthetic and OTel telemetry events.

  Maintains the most recent events (default: 100) so that administrators opening
  the `/admin/telemetry` inspector immediately see historical context before
  new live events arrive over Phoenix PubSub.
  """
  use GenServer

  @max_events 100

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Starts the event buffer GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pushes an event payload into the circular buffer.
  """
  @spec push(map()) :: :ok
  def push(event) when is_map(event) do
    GenServer.cast(__MODULE__, {:push, event})
  end

  @doc """
  Returns the list of recent events (most recent first).
  """
  @spec list() :: [map()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Clears all recorded events from the buffer.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  @doc """
  Returns summary statistics across currently buffered events.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, []}
  end

  @impl true
  def handle_cast({:push, event}, events) do
    updated = [event | Enum.take(events, @max_events - 1)]
    {:noreply, updated}
  end

  @impl true
  def handle_cast(:clear, _events) do
    {:noreply, []}
  end

  @impl true
  def handle_call(:list, _from, events) do
    {:reply, events, events}
  end

  @impl true
  def handle_call(:stats, _from, events) do
    stats = compute_stats(events)
    {:reply, stats, events}
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp compute_stats(events) do
    total = length(events)

    http_events = Enum.filter(events, &(&1.type == :http))
    uptime_events = Enum.filter(events, &(&1.type == :uptime))
    incident_events = Enum.filter(events, &(&1.type == :incident))
    web_vitals_events = Enum.filter(events, &(&1.type == :web_vitals))
    a11y_events = Enum.filter(events, &(&1.type == :a11y))
    dns_events = Enum.filter(events, &(&1.type == :dns))
    security_headers_events = Enum.filter(events, &(&1.type == :security_headers))
    sca_events = Enum.filter(events, &(&1.type == :sca))
    tls_events = Enum.filter(events, &(&1.type == :tls))
    probe_events = Enum.filter(events, &(&1.type == :probe))

    durations =
      (http_events ++ uptime_events)
      |> Enum.map(fn ev ->
        get_in(ev, [:measurements, :duration_ms]) ||
          get_in(ev, [:measurements, :response_time_ms])
      end)
      |> Enum.reject(&is_nil/1)

    avg_latency =
      if durations != [] do
        round(Enum.sum(durations) / length(durations))
      else
        0
      end

    error_count =
      Enum.count(events, fn e ->
        status = get_in(e, [:metadata, "http.response.status_code"])
        is_up = get_in(e, [:metadata, "is_up"])
        error_type = get_in(e, [:metadata, "error.type"])
        (is_integer(status) and status >= 400) or is_up == false or not is_nil(error_type)
      end)

    vuln_count =
      sca_events
      |> Enum.map(&get_in(&1, [:measurements, :vulnerability_count]))
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    %{
      total: total,
      http_count: length(http_events),
      uptime_count: length(uptime_events),
      incident_count: length(incident_events),
      web_vitals_count: length(web_vitals_events),
      a11y_count: length(a11y_events),
      dns_count: length(dns_events),
      security_headers_count: length(security_headers_events),
      sca_count: length(sca_events),
      tls_count: length(tls_events),
      probe_count: length(probe_events),
      avg_latency_ms: avg_latency,
      error_count: error_count,
      total_vulnerabilities: vuln_count
    }
  end
end
