defmodule RavnerWeb.UptimeLive.Show do
  use RavnerWeb, :live_view

  alias Ravner.Uptime
  alias Ravner.Domains

  @impl true
  def mount(%{"domain_id" => domain_id}, _session, socket) do
    domain_id = String.to_integer(domain_id)
    domain = Domains.get_domain_with_preloads!(domain_id)

    # Check if monitoring is active
    monitoring_active =
      domain.domain_metadata && domain.domain_metadata.heartbeat_interval_minutes != nil

    {:ok,
     socket
     |> assign(:page_title, "Uptime — #{domain.name}")
     |> assign(:domain, domain)
     |> assign(:domain_id, domain_id)
     |> assign(:range, "7d")
     |> assign(:monitoring_active, monitoring_active)
     |> assign(:selected_day, nil)
     |> assign(:daily_stats, [])
     |> load_data()}
  end

  @impl true
  def handle_event("set_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:range, range) |> assign(:selected_day, nil) |> load_data()}
  end

  @impl true
  def handle_event("select_day", %{"date" => date_str}, socket) do
    date = Date.from_iso8601!(date_str)
    day_stat = Enum.find(socket.assigns.daily_stats, &(&1.date == date))
    {:noreply, assign(socket, :selected_day, day_stat)}
  end

  @impl true
  def handle_event("clear_day", _params, socket) do
    {:noreply, assign(socket, :selected_day, nil)}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    domain = socket.assigns.domain
    daily = socket.assigns.daily_stats

    csv =
      ["Date,Uptime %,Incidents,Avg Response (ms)\n" |
       Enum.map(daily, fn d ->
         "#{d.date},#{d.uptime_percent},#{d.incidents},#{d.avg_response_ms || ""}\n"
       end)]
      |> IO.iodata_to_binary()

    filename = "uptime_#{domain.name}_#{socket.assigns.range}.csv"

    {:noreply,
     socket
     |> push_event("download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_event(
        "add_note",
        %{"note" => %{"content" => content}, "window_id" => window_id},
        socket
      ) do
    user = socket.assigns.current_scope.user

    case Uptime.create_note(%{
           content: content,
           downtime_window_id: String.to_integer(window_id),
           author_id: user.id
         }) do
      {:ok, _} -> {:noreply, load_data(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to add note.")}
    end
  end

  defp load_data(socket) do
    domain_id = socket.assigns.domain_id
    {from_dt, to_dt} = range_to_dates(socket.assigns.range)

    open_window = Uptime.open_downtime(domain_id)
    status = if open_window, do: :down, else: :up

    bar_data = Uptime.uptime_bar_data(domain_id, 30)
    response_points = Uptime.response_time_series(domain_id, range_to_hours(socket.assigns.range))
    daily = Uptime.daily_stats(domain_id, range_to_days(socket.assigns.range))
    uptime_pct = Uptime.uptime_percent(domain_id, from_dt, to_dt)

    today = Date.utc_today()
    first_of_month = Date.beginning_of_month(today)

    calendar_days =
      Uptime.daily_stats(domain_id, 30)
      |> Enum.filter(fn d -> Date.compare(d.date, first_of_month) != :lt end)
      |> Enum.map(fn d -> %{date: d.date, uptime_percent: d.uptime_percent} end)

    windows = Uptime.downtime_windows(domain_id, from_dt, to_dt)

    windows_with_notes =
      Enum.map(windows, fn w ->
        Map.put(w, :notes, Uptime.list_notes(w.id))
      end)

    # Check if we have any actual data
    has_data = bar_data != [] && Enum.any?(bar_data, fn d -> d.percent != 100.0 end) ||
               response_points != [] || windows != []

    socket
    |> assign(:status, status)
    |> assign(:uptime_percent, uptime_pct)
    |> assign(:bar_data, bar_data)
    |> assign(:response_points, response_points)
    |> assign(:daily_stats, daily)
    |> assign(:calendar_days, calendar_days)
    |> assign(:calendar_month, first_of_month)
    |> assign(:windows, windows_with_notes)
    |> assign(:incident_count, length(windows))
    |> assign(:has_data, has_data)
  end

  defp range_to_dates("24h"), do: {DateTime.add(DateTime.utc_now(), -1, :day), DateTime.utc_now()}
  defp range_to_dates("7d"), do: {DateTime.add(DateTime.utc_now(), -7, :day), DateTime.utc_now()}
  defp range_to_dates("30d"), do: {DateTime.add(DateTime.utc_now(), -30, :day), DateTime.utc_now()}
  defp range_to_dates(_), do: range_to_dates("7d")

  defp range_to_hours("24h"), do: 24
  defp range_to_hours("7d"), do: 168
  defp range_to_hours("30d"), do: 720
  defp range_to_hours(_), do: 168

  defp range_to_days("24h"), do: 1
  defp range_to_days("7d"), do: 7
  defp range_to_days("30d"), do: 30
  defp range_to_days(_), do: 7

  defp format_duration(nil), do: "\u2014"
  defp format_duration(0), do: "0s"
  defp format_duration(s) when s < 60, do: "#{s}s"
  defp format_duration(s) when s < 3600, do: "#{div(s, 60)}m"
  defp format_duration(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
end
