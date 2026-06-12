defmodule RavnerWeb.OwnershipLive.ProjectShow do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Inventory.get_project!(id)
    stats = OwnershipStats.project_stats(id)
    team = OwnershipStats.list_team_for_project(id)
    domains = OwnershipStats.list_domains_for_project(id)
    repositories = Inventory.list_project_repositories(id)

    {:ok,
     socket
     |> assign(:page_title, project.display_name || project.name)
     |> assign(:project, project)
     |> assign(:stats, stats)
     |> assign(:team, team)
     |> assign(:domains, domains)
     |> assign(:repositories, repositories)
     |> assign(:current_tab, "team")}
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
