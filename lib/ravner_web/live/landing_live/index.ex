defmodule RavnerWeb.LandingLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Domains
  alias Ravner.Repo

  @impl true
  def mount(_params, _session, socket) do
    if authenticated?(socket) do
      {:ok, assign_pulse(socket)}
    else
      {:ok, assign(socket, :page_title, "Ravner")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :detail_popup, nil)}
  end

  @impl true
  def handle_event("show_detail", %{"section" => section}, socket) do
    {:noreply, assign(socket, :detail_popup, section)}
  end

  @impl true
  def handle_event("close_detail", _, socket) do
    {:noreply, assign(socket, :detail_popup, nil)}
  end

  # --- Private ---

  defp authenticated?(socket) do
    socket.assigns[:current_scope] && socket.assigns.current_scope.user
  end

  defp assign_pulse(socket) do
    import Ecto.Query

    stats = Domains.dashboard_stats()
    user = socket.assigns.current_scope.user

    # A11y compliance numbers
    a11y_scanned =
      Repo.one(
        from(s in "a11y_scans",
          where: s.status == "completed",
          select: count(fragment("DISTINCT ?", s.domain_id))
        )
      ) || 0

    a11y_compliant =
      Repo.one(
        from(s in "a11y_scans",
          where: s.status == "completed" and s.violations_count == 0,
          select: count(fragment("DISTINCT ?", s.domain_id))
        )
      ) || 0

    # Security scan count
    security_findings =
      Repo.one(
        from(s in "security_scans",
          join: f in "scan_findings",
          on: f.security_scan_id == s.id,
          where: s.status == "completed",
          select: count(f.id)
        )
      ) || 0

    # Uptime summary
    monitors = Ravner.Uptime.list_monitored_domains()
    now = DateTime.utc_now()
    thirty_days_ago = DateTime.add(now, -30, :day)
    week_ago = DateTime.add(now, -7, :day)

    monitored_count = length(monitors)
    up_count = Enum.count(monitors, fn m -> m.is_up == true end)
    down_count = Enum.count(monitors, fn m -> m.is_up == false end)

    avg_uptime =
      if monitored_count > 0 do
        monitors
        |> Enum.map(fn m -> Ravner.Uptime.uptime_percent(m.domain_id, thirty_days_ago, now) end)
        |> Enum.sum()
        |> Kernel./(monitored_count)
        |> Float.round(1)
      else
        nil
      end

    recent_incidents =
      monitors
      |> Enum.flat_map(fn m ->
        Ravner.Uptime.downtime_windows(m.domain_id, week_ago, now)
        |> Enum.map(fn w -> Map.put(w, :domain, m.domain) end)
      end)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.take(3)

    socket
    |> assign(:page_title, "Ravner")
    |> assign(:user_name, user.name || user.email)
    |> assign(:pulse, %{
      total_domains: stats.total,
      total_apex: stats.total_apex,
      http_200: stats.http.http_200,
      http_errors: stats.http.http_4xx_5xx,
      http_total: stats.http.http_200 + stats.http.http_3xx + stats.http.http_4xx_5xx,
      ssl_expiring: stats.ssl.expired + stats.ssl.soon_7d,
      ssl_healthy: max(0, stats.ssl.total - stats.ssl.expired - stats.ssl.soon_7d),
      ssl_total: stats.ssl.total,
      a11y_scanned: a11y_scanned,
      a11y_compliant: a11y_compliant,
      security_findings: security_findings,
      governance_gaps: stats.governance.missing_project + stats.governance.missing_pm,
      monitored_count: monitored_count,
      up_count: up_count,
      down_count: down_count,
      avg_uptime: avg_uptime,
      recent_incidents: recent_incidents
    })
  end
end
