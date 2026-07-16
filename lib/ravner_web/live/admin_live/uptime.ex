defmodule RavnerWeb.AdminLive.Uptime do
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

    enriched =
      Enum.map(monitors, fn meta ->
        open_window = Uptime.open_downtime(meta.domain_id)

        status =
          cond do
            open_window -> :down
            meta.is_up == false -> :degraded
            true -> :up
          end

        %{
          domain: meta.domain,
          meta: meta,
          status: status,
          open_window: open_window
        }
      end)

    assign(socket, :monitors, enriched)
  end
end
