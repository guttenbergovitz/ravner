defmodule RavnerWeb.OwnershipLive.PersonShow do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    person = Inventory.get_person!(id)
    stats = OwnershipStats.person_stats(id)
    all_roles = OwnershipStats.list_roles_for_person(id)

    pm_projects = OwnershipStats.list_pm_projects_for_person(id)
    po_projects = OwnershipStats.list_po_projects_for_person(id)
    managed_brands = OwnershipStats.list_brands_for_person(id)
    managed_orgs = OwnershipStats.list_organizations_for_person(id)

    {:ok,
     socket
     |> assign(:page_title, "#{person.first_name} #{person.last_name}")
     |> assign(:person, person)
     |> assign(:stats, stats)
     |> assign(:pm_projects, pm_projects)
     |> assign(:po_projects, po_projects)
     |> assign(:managed_brands, managed_brands)
     |> assign(:managed_orgs, managed_orgs)
     |> assign(:all_roles, all_roles)
     |> assign(:roles, all_roles)
     |> assign(:search_query, "")}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    search_term = String.downcase(query)

    filtered =
      if search_term == "" do
        socket.assigns.all_roles
      else
        Enum.filter(socket.assigns.all_roles, fn r ->
          String.contains?(String.downcase(r.project_name), search_term) ||
            String.contains?(String.downcase(r.organization_name), search_term) ||
            String.contains?(String.downcase(r.role), search_term)
        end)
      end

    {:noreply, assign(socket, roles: filtered, search_query: query)}
  end
end
