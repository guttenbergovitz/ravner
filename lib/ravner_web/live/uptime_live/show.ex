defmodule RavnerWeb.UptimeLive.Show do
  use RavnerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Uptime Detail")}
  end
end
