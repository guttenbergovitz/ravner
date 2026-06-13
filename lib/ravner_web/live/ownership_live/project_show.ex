defmodule RavnerWeb.OwnershipLive.ProjectShow do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Inventory.get_project!(id)
    stats = OwnershipStats.project_stats(id)
    all_team = OwnershipStats.list_team_for_project(id)
    all_domains = OwnershipStats.list_domains_for_project(id)
    all_repositories = Inventory.list_project_repositories(id)

    {:ok,
     socket
     |> assign(:page_title, project.display_name || project.name)
     |> assign(:project, project)
     |> assign(:stats, stats)
     |> assign(:all_team, all_team)
     |> assign(:all_domains, all_domains)
     |> assign(:all_repositories, all_repositories)
     |> assign(:team, all_team)
     |> assign(:domains, all_domains)
     |> assign(:repositories, all_repositories)
     |> assign(:current_tab, "team")
     |> assign(:search_query, "")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = Map.get(params, "tab", "team")
    {:noreply, assign(socket, :current_tab, tab)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    search_term = String.downcase(query)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:team, filter_team(socket.assigns.all_team, search_term))
     |> assign(:repositories, filter_repos(socket.assigns.all_repositories, search_term))
     |> assign(:domains, filter_project_domains(socket.assigns.all_domains, search_term))}
  end

  defp filter_team(team, ""), do: team

  defp filter_team(team, term) do
    Enum.filter(team, fn m ->
      full_name = "#{m.first_name} #{m.last_name}" |> String.downcase()

      String.contains?(full_name, term) ||
        (m.title && String.contains?(String.downcase(m.title), term)) ||
        (m.email && String.contains?(String.downcase(m.email), term)) ||
        String.contains?(String.downcase(m.role), term)
    end)
  end

  defp filter_repos(repos, ""), do: repos

  defp filter_repos(repos, term) do
    Enum.filter(repos, fn r ->
      String.contains?(String.downcase(r.url), term) ||
        (r.notes && String.contains?(String.downcase(r.notes), term)) ||
        (r.kind && String.contains?(String.downcase(r.kind), term))
    end)
  end

  defp filter_project_domains(domains, ""), do: domains

  defp filter_project_domains(domains, term) do
    Enum.filter(domains, fn d ->
      String.contains?(String.downcase(d.name), term)
    end)
  end
end
