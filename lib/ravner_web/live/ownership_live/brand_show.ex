defmodule RavnerWeb.OwnershipLive.BrandShow do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    brand = Inventory.get_brand!(id)
    stats = OwnershipStats.brand_stats(id)
    organizations = OwnershipStats.list_organizations_for_brand(id)

    {:ok,
     socket
     |> assign(:page_title, brand.display_name || brand.name)
     |> assign(:brand, brand)
     |> assign(:stats, stats)
     |> assign(:organizations, organizations)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end
