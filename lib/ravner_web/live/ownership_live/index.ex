defmodule RavnerWeb.OwnershipLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(_params, _session, socket) do
    stats = OwnershipStats.dashboard_stats()
    brands = OwnershipStats.list_brands_with_stats()

    {:ok,
     socket
     |> assign(:page_title, "Ownership")
     |> assign(:stats, stats)
     |> assign(:brands, brands)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end
