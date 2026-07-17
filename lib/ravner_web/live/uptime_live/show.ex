defmodule RavnerWeb.UptimeLive.Show do
  use RavnerWeb, :live_view

  alias Ravner.Uptime
  alias Ravner.Uptime.Notifications
  alias Ravner.Domains

  @impl true
  def mount(%{"domain_id" => domain_id}, _session, socket) do
    domain_id = String.to_integer(domain_id)
    domain = Domains.get_domain_with_preloads!(domain_id)

    monitoring_active =
      domain.domain_metadata && domain.domain_metadata.heartbeat_interval_minutes != nil

    {:ok,
     socket
     |> assign(:page_title, "Uptime — #{domain.name}")
     |> assign(:domain, domain)
     |> assign(:domain_id, domain_id)
     |> assign(:monitoring_active, monitoring_active)
     |> assign(:view_level, :month)
     |> assign(:selected_date, nil)
     |> assign(:selected_day_stat, nil)
     |> assign(:hourly_data, nil)
     |> load_data()}
  end

  # --- Drill-down events ---

  @impl true
  def handle_event("select_day", %{"date" => date_str}, socket) do
    date = Date.from_iso8601!(date_str)
    today = Date.utc_today()

    # Don't drill into future days or days without data
    if Date.compare(date, today) != :gt do
      hourly = Uptime.hourly_stats(socket.assigns.domain_id, date)
      day_stat = Enum.find(socket.assigns.daily_stats, &(&1.date == date))

      {:noreply,
       socket
       |> assign(:view_level, :day)
       |> assign(:selected_date, date)
       |> assign(:hourly_data, hourly)
       |> assign(:selected_day_stat, day_stat)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("back_to_month", _params, socket) do
    {:noreply,
     socket
     |> assign(:view_level, :month)
     |> assign(:selected_date, nil)
     |> assign(:hourly_data, nil)}
  end

  @impl true
  def handle_event("purge_data", _params, socket) do
    if socket.assigns.current_scope.user.role == :admin do
      {checks, windows} = Uptime.purge_domain_data(socket.assigns.domain_id)

      {:noreply,
       socket
       |> put_flash(:info, "Purged #{checks} checks and #{windows} downtime windows.")
       |> assign(:view_level, :month)
       |> assign(:selected_date, nil)
       |> assign(:hourly_data, nil)
       |> load_data()}
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    domain = socket.assigns.domain
    daily = socket.assigns.daily_stats

    csv =
      ["Date,Uptime %,Incidents,Avg Response (ms)\n" |
       Enum.map(daily, fn d ->
         pct = if d.uptime_percent, do: "#{d.uptime_percent}", else: "N/A"
         resp = if d.avg_response_ms, do: "#{d.avg_response_ms}", else: ""
         "#{d.date},#{pct},#{d.incidents},#{resp}\n"
       end)]
      |> IO.iodata_to_binary()

    filename = "uptime_#{domain.name}_30d.csv"

    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
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

    # Status summary (human-readable)
    summary = Uptime.status_summary(domain_id)

    # 30-day data for bar and calendar
    daily = Uptime.daily_stats(domain_id, 30)
    bar_data = Enum.map(daily, fn d -> %{date: d.date, percent: d.uptime_percent} end)

    today = Date.utc_today()
    first_of_month = Date.beginning_of_month(today)

    calendar_days =
      daily
      |> Enum.filter(fn d -> Date.compare(d.date, first_of_month) != :lt end)
      |> Enum.map(fn d -> %{date: d.date, uptime_percent: d.uptime_percent} end)

    # Response time (last 24h)
    response_points = Uptime.response_time_series(domain_id, 24)

    # Recent incidents (30 days)
    from_dt = DateTime.add(DateTime.utc_now(), -30, :day)
    to_dt = DateTime.utc_now()
    windows = Uptime.downtime_windows(domain_id, from_dt, to_dt)

    windows_with_notes =
      Enum.map(windows, fn w ->
        Map.put(w, :notes, Uptime.list_notes(w.id))
      end)

    # 30-day uptime
    uptime_pct = Uptime.uptime_percent(domain_id, from_dt, to_dt)

    # Notification recipients
    recipients = Notifications.resolve_recipients(domain_id)

    # Has any real data?
    has_data = Enum.any?(daily, fn d -> d.uptime_percent != nil end)

    socket
    |> assign(:summary, summary)
    |> assign(:uptime_percent, uptime_pct)
    |> assign(:bar_data, bar_data)
    |> assign(:response_points, response_points)
    |> assign(:daily_stats, daily)
    |> assign(:calendar_days, calendar_days)
    |> assign(:calendar_month, first_of_month)
    |> assign(:windows, windows_with_notes)
    |> assign(:incident_count, length(windows))
    |> assign(:has_data, has_data)
    |> assign(:recipients, recipients)
  end

  defp format_duration(nil), do: "\u2014"
  defp format_duration(0), do: "0s"
  defp format_duration(s) when s < 60, do: "#{s}s"
  defp format_duration(s) when s < 3600, do: "#{div(s, 60)}m"
  defp format_duration(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
end
