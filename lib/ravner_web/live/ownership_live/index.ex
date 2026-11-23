defmodule RavnerWeb.OwnershipLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:current_scope]
    stats = OwnershipStats.dashboard_stats(scope)

    all_brands =
      OwnershipStats.list_brands_with_stats()
      |> filter_brands_by_scope(scope)

    orphaned = OwnershipStats.orphaned_stats(scope)

    {:ok,
     socket
     |> assign(:page_title, "Ownership")
     |> assign(:stats, stats)
     |> assign(:all_brands, all_brands)
     |> assign(:brands, all_brands)
     |> assign(:orphaned, orphaned)
     |> assign(:search_query, "")}
  end

  defp filter_brands_by_scope(brands, nil), do: brands
  defp filter_brands_by_scope(brands, %{global?: true}), do: brands

  defp filter_brands_by_scope(brands, scope) do
    Enum.filter(brands, &(&1.id in scope.brand_ids))
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    filtered =
      socket.assigns.all_brands
      |> Enum.filter(fn brand ->
        search_term = String.downcase(query)

        search_term == "" ||
          String.contains?(String.downcase(brand.name), search_term) ||
          (brand.display_name &&
             String.contains?(String.downcase(brand.display_name), search_term))
      end)

    {:noreply, assign(socket, brands: filtered, search_query: query)}
  end
end
