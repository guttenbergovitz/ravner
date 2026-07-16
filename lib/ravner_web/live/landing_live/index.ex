defmodule RavnerWeb.LandingLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.A11y
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

    # Recent scans (last 5 a11y)
    recent_a11y =
      Repo.all(
        from(s in A11y.A11yScan,
          join: d in assoc(s, :domain),
          where: s.status == "completed",
          order_by: [desc: s.completed_at],
          limit: 5,
          select: %{
            domain_name: d.name,
            domain_id: d.id,
            violations: s.violations_count,
            at: s.completed_at
          }
        )
      )

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

    # System health
    pa11y_ok = System.find_executable("pa11y") != nil
    nuclei_ok = System.find_executable("nuclei") != nil

    socket
    |> assign(:page_title, "Ravner")
    |> assign(:pulse, %{
      total_domains: stats.total,
      total_apex: stats.total_apex,
      http_200: stats.http.http_200,
      http_errors: stats.http.http_4xx_5xx,
      ssl_expiring: stats.ssl.expired + stats.ssl.soon_7d,
      ssl_total: stats.ssl.total,
      a11y_scanned: a11y_scanned,
      a11y_compliant: a11y_compliant,
      security_findings: security_findings,
      recent_a11y: recent_a11y,
      pa11y_ok: pa11y_ok,
      nuclei_ok: nuclei_ok
    })
  end
end
