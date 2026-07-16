defmodule RavnerWeb.DashboardLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Domains
  alias Ravner.Uptime

  @impl true
  def mount(_params, _session, socket) do
    stats = Domains.dashboard_stats()

    http_chart = build_http_chart(stats.http)
    scan_chart = build_scan_chart(stats.scan)

    top_subs_max =
      case stats.top_by_subs do
        [{_, max} | _] -> max
        _ -> 1
      end

    # Uptime summary
    uptime_summary = build_uptime_summary()

    {:ok,
     socket
     |> assign(:page_title, "Ravner")
     |> assign(:stats, stats)
     |> assign(:http_chart, http_chart)
     |> assign(:scan_chart, scan_chart)
     |> assign(:top_subs_max, top_subs_max)
     |> assign(:uptime_summary, uptime_summary)
     |> assign(:current_tab, "risks")}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :detail_popup, nil)}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :current_tab, tab)}
  end

  @impl true
  def handle_event("show_detail", %{"section" => section}, socket) do
    {:noreply, assign(socket, :detail_popup, section)}
  end

  @impl true
  def handle_event("close_detail", _, socket) do
    {:noreply, assign(socket, :detail_popup, nil)}
  end

  defp build_http_chart(http) do
    data = [
      %{label: "200 OK", value: http.http_200, color: "#737373"},
      %{label: "3xx redirect", value: http.http_3xx, color: "#a3a3a3"},
      %{label: "4xx/5xx", value: http.http_4xx_5xx, color: "#d4d4d4"},
      %{label: "not scanned", value: http.http_unscanned, color: "#f0f0f0"}
    ]

    total = http.http_200 + http.http_3xx + http.http_4xx_5xx + http.http_unscanned
    build_bar_chart_svg(data, total)
  end

  defp build_scan_chart(scan) do
    data = [
      %{label: "this week", value: scan.this_week, color: "#737373"},
      %{label: "this month", value: scan.this_month, color: "#a3a3a3"},
      %{label: "older", value: scan.older, color: "#d4d4d4"},
      %{label: "never", value: scan.never, color: "#f0f0f0"}
    ]

    total = scan.this_week + scan.this_month + scan.older + scan.never
    build_bar_chart_svg(data, total)
  end

  defp build_bar_chart_svg(data, total) do
    bar_height = 6
    gap = 4
    label_width = 80
    value_width = 36
    margin_left = label_width
    margin_right = value_width + 4

    chart_width = 300
    max_bar_width = chart_width - margin_left - margin_right

    bars =
      Enum.map_join(data, "\n", fn %{value: value, label: label, color: color} ->
        pct = if total > 0, do: value / total, else: 0
        bar_w = max(ceil(pct * max_bar_width), 1)

        ~s"""
        <div style="display:flex;align-items:center;gap:0;margin-bottom:#{gap}px;font-size:10px;line-height:#{bar_height + gap}px;height:#{bar_height + gap}px;">
          <span style="width:#{label_width}px;color:#a3a3a3;text-align:right;padding-right:8px;display:inline-block;">#{label}</span>
          <div style="height:#{bar_height}px;background:#e5e5e5;flex:1;">
            <div style="height:#{bar_height}px;background:#{color};width:#{bar_w}px;transition:width 0.4s ease;"></div>
          </div>
          <span style="width:#{value_width}px;color:#525252;text-align:right;padding-left:4px;display:inline-block;">#{value}</span>
        </div>
        """
      end)

    bars
  end

  defp build_uptime_summary do
    monitors = Uptime.list_monitored_domains()
    now = DateTime.utc_now()
    thirty_days_ago = DateTime.add(now, -30, :day)

    monitored_count = length(monitors)

    up_count = Enum.count(monitors, fn m -> m.is_up == true end)
    down_count = Enum.count(monitors, fn m -> m.is_up == false end)

    # Recent incidents (last 7 days)
    week_ago = DateTime.add(now, -7, :day)

    recent_incidents =
      monitors
      |> Enum.flat_map(fn m ->
        Uptime.downtime_windows(m.domain_id, week_ago, now)
        |> Enum.map(fn w -> Map.put(w, :domain, m.domain) end)
      end)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.take(5)

    avg_uptime =
      if monitored_count > 0 do
        monitors
        |> Enum.map(fn m -> Uptime.uptime_percent(m.domain_id, thirty_days_ago, now) end)
        |> Enum.sum()
        |> Kernel./(monitored_count)
        |> Float.round(2)
      else
        100.0
      end

    %{
      monitored: monitored_count,
      up: up_count,
      down: down_count,
      avg_uptime: avg_uptime,
      recent_incidents: recent_incidents
    }
  end
end
