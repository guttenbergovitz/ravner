defmodule RavnerWeb.OwnershipLive.BrandShow do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    brand = Inventory.get_brand!(id)
    stats = OwnershipStats.brand_stats(id)
    all_organizations = OwnershipStats.list_organizations_for_brand(id)

    {:ok,
     socket
     |> assign(:page_title, brand.display_name || brand.name)
     |> assign(:brand, brand)
     |> assign(:stats, stats)
     |> assign(:all_organizations, all_organizations)
     |> assign(:organizations, all_organizations)
     |> assign(:projects, [])
     |> assign(:people, [])
     |> assign(:domains, [])
     |> assign(:current_tab, "organizations")
     |> assign(:search_query, "")}
  end

  @impl true
  def handle_params(%{"tab" => tab} = _params, _url, socket) do
    socket =
      case tab do
        "projects" ->
          assign(
            socket,
            :projects,
            OwnershipStats.list_projects_for_brand(socket.assigns.brand.id)
          )

        "people" ->
          assign(socket, :people, OwnershipStats.list_people_for_brand(socket.assigns.brand.id))

        "domains" ->
          assign(socket, :domains, OwnershipStats.list_domains_for_brand(socket.assigns.brand.id))

        _ ->
          socket
      end

    {:noreply, assign(socket, :current_tab, tab)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :current_tab, "organizations")}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    search_term = String.downcase(query)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(
       :organizations,
       filter_organizations(socket.assigns.all_organizations, search_term)
     )}
  end

  defp filter_organizations(orgs, ""), do: orgs

  defp filter_organizations(orgs, term) do
    Enum.filter(orgs, fn org ->
      String.contains?(String.downcase(org.name), term) ||
        (org.display_name && String.contains?(String.downcase(org.display_name), term)) ||
        (org.country && String.contains?(String.downcase(org.country), term))
    end)
  end
end
