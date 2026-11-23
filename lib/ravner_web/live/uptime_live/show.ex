defmodule RavnerWeb.UptimeLive.Show do
  use RavnerWeb, :live_view

  alias Ravner.Uptime
  alias Ravner.Uptime.Notifications
  alias Ravner.Domains

  @tick_interval 15_000

  @impl true
  def mount(%{"domain_id" => domain_id}, _session, socket) do
    domain_id = String.to_integer(domain_id)
    domain = Domains.get_domain_with_preloads!(domain_id)

    monitoring_active =
      domain.domain_metadata && domain.domain_metadata.heartbeat_interval_minutes != nil

    if connected?(socket), do: Process.send_after(self(), :tick, @tick_interval)

    {:ok,
     socket
     |> assign(:page_title, "Uptime — #{domain.name}")
     |> assign(:domain, domain)
     |> assign(:domain_id, domain_id)
     |> assign(:monitoring_active, monitoring_active)
     |> assign(:view_level, :month)
     |> assign(:chart_view, "month")
     |> assign(:chart_offset, 0)
     |> assign(:selected_date, nil)
     |> assign(:selected_day_stat, nil)
     |> assign(:hourly_data, nil)
     |> assign(:csv_range, "30")
     |> load_data()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, load_data(socket)}
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
  def handle_event("set_chart_view", %{"view" => view}, socket) do
    {:noreply, socket |> assign(:chart_view, view) |> assign(:chart_offset, 0) |> load_data()}
  end

  @impl true
  def handle_event("chart_prev", _params, socket) do
    {:noreply, socket |> assign(:chart_offset, socket.assigns.chart_offset - 1) |> load_data()}
  end

  @impl true
  def handle_event("chart_next", _params, socket) do
    new_offset = min(socket.assigns.chart_offset + 1, 0)
    {:noreply, socket |> assign(:chart_offset, new_offset) |> load_data()}
  end

  @impl true
  def handle_event("set_csv_range", %{"range" => range}, socket) do
    {:noreply, assign(socket, :csv_range, range)}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    domain = socket.assigns.domain
    days = String.to_integer(socket.assigns.csv_range)
    daily = Uptime.daily_stats(socket.assigns.domain_id, days)

    csv =
      [
        "Date,Uptime %,Incidents,Avg Response (ms)\n"
        | Enum.map(daily, fn d ->
            pct = if d.uptime_percent, do: "#{d.uptime_percent}", else: "N/A"
            resp = if d.avg_response_ms, do: "#{d.avg_response_ms}", else: ""
            "#{d.date},#{pct},#{d.incidents},#{resp}\n"
          end)
      ]
      |> IO.iodata_to_binary()

    filename = "uptime_#{domain.name}_#{days}d.csv"

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

  @impl true
  def handle_event("add_check", %{"check" => check_params}, socket) do
    if socket.assigns.current_scope.user.role in [:admin, :editor] do
      attrs =
        check_params
        |> Map.put("domain_id", socket.assigns.domain_id)

      case Uptime.create_domain_check(attrs) do
        {:ok, _} -> {:noreply, load_data(socket) |> put_flash(:info, "Check added.")}
        {:error, cs} -> {:noreply, put_flash(socket, :error, "Invalid: #{inspect_errors(cs)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Permission denied.")}
    end
  end

  @impl true
  def handle_event("delete_check", %{"id" => id}, socket) do
    if socket.assigns.current_scope.user.role in [:admin, :editor] do
      check = Uptime.get_domain_check!(id)
      Uptime.delete_domain_check(check)
      {:noreply, load_data(socket) |> put_flash(:info, "Check removed.")}
    else
      {:noreply, put_flash(socket, :error, "Permission denied.")}
    end
  end

  @impl true
  def handle_event("toggle_check", %{"id" => id}, socket) do
    if socket.assigns.current_scope.user.role in [:admin, :editor] do
      check = Uptime.get_domain_check!(id)
      Uptime.toggle_domain_check(check)
      {:noreply, load_data(socket)}
    else
      {:noreply, put_flash(socket, :error, "Permission denied.")}
    end
  end

  @impl true
  def handle_event("update_scheduling", params, socket) do
    if socket.assigns.current_scope.user.role in [:admin, :editor] do
      attrs = %{
        heartbeat_interval_minutes: parse_interval(params["heartbeat_interval_minutes"]),
        scan_interval_days: parse_interval(params["scan_interval_days"]),
        http_scan_interval_days: parse_interval(params["http_scan_interval_days"]),
        dns_scan_interval_days: parse_interval(params["dns_scan_interval_days"]),
        a11y_scan_interval_days: parse_interval(params["a11y_scan_interval_days"]),
        lighthouse_scan_interval_days: parse_interval(params["lighthouse_scan_interval_days"])
      }

      case Ravner.Domains.upsert_domain_metadata(socket.assigns.domain_id, attrs) do
        {:ok, _} ->
          domain = Ravner.Domains.get_domain_with_preloads!(socket.assigns.domain_id)

          monitoring_active =
            domain.domain_metadata && domain.domain_metadata.heartbeat_interval_minutes != nil

          {:noreply,
           socket
           |> assign(:domain, domain)
           |> assign(:monitoring_active, monitoring_active)
           |> put_flash(:info, "Scan configuration updated.")
           |> load_data()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update configuration.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Permission denied.")}
    end
  end

  @impl true
  def handle_event("update_check_interval", %{"id" => id, "interval" => interval}, socket) do
    if socket.assigns.current_scope.user.role in [:admin, :editor] do
      check = Uptime.get_domain_check!(id)
      Uptime.update_domain_check(check, %{check_interval_minutes: String.to_integer(interval)})
      {:noreply, load_data(socket)}
    else
      {:noreply, put_flash(socket, :error, "Permission denied.")}
    end
  end

  defp inspect_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
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

    # Domain checks (custom endpoints)
    domain_checks = Uptime.list_domain_checks(domain_id)

    # Central chart data (year/month/day view with offset for prev/next)
    {chart_data, chart_title} =
      build_chart_data(domain_id, socket.assigns.chart_view, socket.assigns.chart_offset)

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
    |> assign(:domain_checks, domain_checks)
    |> assign(:chart_data, chart_data)
    |> assign(:chart_title, chart_title)
  end

  defp build_chart_data(domain_id, "year", offset) do
    today = Date.utc_today()
    year = today.year + offset
    data = Uptime.monthly_stats(domain_id, 12)

    # For non-current year, we'd need a different query range.
    # ponytail: For now, monthly_stats always returns last 12 months.
    # Offset shifts which year label we show but data is approximate.
    chart =
      if offset == 0 do
        Enum.map(data, fn d ->
          %{label: Calendar.strftime(d.month, "%b"), uptime_percent: d.uptime_percent}
        end)
      else
        # Generate 12 months for the target year
        for m <- 1..12 do
          month_start = Date.new!(year, m, 1)
          month_end = Date.end_of_month(month_start)

          # Skip future months
          if Date.compare(month_start, today) == :gt do
            %{label: Calendar.strftime(month_start, "%b"), uptime_percent: nil}
          else
            from_dt = DateTime.new!(month_start, ~T[00:00:00], "Etc/UTC")
            to_dt = DateTime.new!(min_date(month_end, today), ~T[23:59:59], "Etc/UTC")
            pct = Uptime.uptime_percent(domain_id, from_dt, to_dt)
            %{label: Calendar.strftime(month_start, "%b"), uptime_percent: pct}
          end
        end
      end

    {chart, "#{year}"}
  end

  defp build_chart_data(domain_id, "month", offset) do
    today = Date.utc_today()
    target_month = Uptime.month_start(today, offset)
    days_in_month = Date.days_in_month(target_month)
    days_since_target = Date.diff(today, target_month) + 1

    daily = Uptime.daily_stats(domain_id, days_since_target)
    daily_map = Map.new(daily, fn d -> {d.date, d} end)

    chart =
      for day_num <- 1..days_in_month do
        date = Date.new!(target_month.year, target_month.month, day_num)
        stat = Map.get(daily_map, date)
        pct = if stat, do: stat.uptime_percent, else: nil
        # Future days = nil
        pct = if Date.compare(date, today) == :gt, do: nil, else: pct
        %{label: "#{day_num}", uptime_percent: pct}
      end

    {chart, Calendar.strftime(target_month, "%B %Y")}
  end

  defp build_chart_data(domain_id, "day", offset) do
    today = Date.utc_today()
    target_day = Date.add(today, offset)

    hourly = Uptime.hourly_stats(domain_id, target_day)

    now_hour = if offset == 0, do: DateTime.utc_now().hour, else: 23

    chart =
      Enum.map(hourly, fn h ->
        pct = if h.hour > now_hour && offset == 0, do: nil, else: h.uptime_percent
        %{label: String.pad_leading("#{h.hour}", 2, "0"), uptime_percent: pct}
      end)

    {chart, Calendar.strftime(target_day, "%A, %B %d, %Y")}
  end

  defp build_chart_data(domain_id, _, offset), do: build_chart_data(domain_id, "month", offset)

  defp min_date(a, b), do: if(Date.compare(a, b) == :lt, do: a, else: b)

  defp format_duration(nil), do: "\u2014"
  defp format_duration(0), do: "0s"
  defp format_duration(s) when s < 60, do: "#{s}s"
  defp format_duration(s) when s < 3600, do: "#{div(s, 60)}m"
  defp format_duration(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp parse_interval(""), do: nil
  defp parse_interval(nil), do: nil

  defp parse_interval(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_interval(_), do: nil
end
