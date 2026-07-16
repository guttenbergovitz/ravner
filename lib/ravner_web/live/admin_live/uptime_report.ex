defmodule RavnerWeb.AdminLive.UptimeReport do
  use RavnerWeb, :live_view

  alias Ravner.Uptime
  alias Ravner.Domains

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Uptime Report")
     |> assign(:range, "7d")
     |> assign(:domain_id, nil)
     |> assign(:report, [])}
  end

  @impl true
  def handle_params(%{"domain_id" => domain_id}, _uri, socket) do
    {:noreply, socket |> assign(:domain_id, domain_id) |> load_report()}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(:domain_id, nil) |> load_report()}
  end

  @impl true
  def handle_event("set_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:range, range) |> load_report()}
  end

  defp load_report(socket) do
    {from_dt, to_dt} = range_to_dates(socket.assigns.range)

    report =
      case socket.assigns.domain_id do
        nil ->
          monitors = Uptime.list_monitored_domains()

          Enum.map(monitors, fn meta ->
            %{
              domain: meta.domain,
              uptime_percent: Uptime.uptime_percent(meta.domain_id, from_dt, to_dt),
              windows: Uptime.downtime_windows(meta.domain_id, from_dt, to_dt)
            }
          end)

        domain_id ->
          domain_id = if is_binary(domain_id), do: String.to_integer(domain_id), else: domain_id
          domain = Domains.get_domain!(domain_id)
          windows = Uptime.downtime_windows(domain_id, from_dt, to_dt)
          checks = Uptime.recent_checks(domain_id, 120)

          [%{
            domain: domain,
            uptime_percent: Uptime.uptime_percent(domain_id, from_dt, to_dt),
            windows: windows,
            checks: checks
          }]
      end

    assign(socket, :report, report)
  end

  defp range_to_dates("24h"), do: {DateTime.add(DateTime.utc_now(), -1, :day), DateTime.utc_now()}
  defp range_to_dates("7d"), do: {DateTime.add(DateTime.utc_now(), -7, :day), DateTime.utc_now()}
  defp range_to_dates("30d"), do: {DateTime.add(DateTime.utc_now(), -30, :day), DateTime.utc_now()}
  defp range_to_dates(_), do: range_to_dates("7d")

  defp format_duration(nil), do: "\u2014"
  defp format_duration(0), do: "0s"
  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
end
