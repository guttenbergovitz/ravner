defmodule RavnerWeb.UptimeLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Uptime

  @tick_interval 15_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_interval)

    {:ok, socket |> assign(:page_title, "Uptime Monitor") |> load_data()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, load_data(socket)}
  end

  defp load_data(socket) do
    monitors = Uptime.list_monitored_domains()
    now = DateTime.utc_now()
    thirty_days_ago = DateTime.add(now, -30, :day)

    enriched =
      Enum.map(monitors, fn meta ->
        open_window = Uptime.open_downtime(meta.domain_id)

        status =
          cond do
            open_window -> :down
            meta.is_up == false -> :degraded
            true -> :up
          end

        bar_data = Uptime.uptime_bar_data(meta.domain_id, 30)
        uptime_pct = Uptime.uptime_percent(meta.domain_id, thirty_days_ago, now)

        %{
          domain: meta.domain,
          meta: meta,
          status: status,
          bar_data: bar_data,
          uptime_percent: uptime_pct
        }
      end)

    up_count = Enum.count(enriched, &(&1.status == :up))
    down_count = Enum.count(enriched, &(&1.status == :down))

    avg_uptime =
      if enriched != [] do
        enriched |> Enum.map(& &1.uptime_percent) |> Enum.sum() |> Kernel./(length(enriched)) |> Float.round(2)
      else
        100.0
      end

    socket
    |> assign(:monitors, enriched)
    |> assign(:up_count, up_count)
    |> assign(:down_count, down_count)
    |> assign(:avg_uptime, avg_uptime)
  end
end
