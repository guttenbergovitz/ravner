defmodule RavnerWeb.OwnershipLive.OrganizationShow do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    org = Inventory.get_organization!(id)
    stats = OwnershipStats.organization_stats(id)
    projects = OwnershipStats.list_projects_for_organization(id)
    people = OwnershipStats.list_people_for_organization(id)
    domains = OwnershipStats.list_domains_for_organization(id)

    {:ok,
     socket
     |> assign(:page_title, org.display_name || org.name)
     |> assign(:org, org)
     |> assign(:stats, stats)
     |> assign(:projects, projects)
     |> assign(:people, people)
     |> assign(:domains, domains)
     |> assign(:current_tab, "projects")}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :current_tab, tab)}
  end
end
