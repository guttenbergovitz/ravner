defmodule RavnerWeb.OwnershipLive.OrganizationShow do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    org = Inventory.get_organization!(id)
    stats = OwnershipStats.organization_stats(id)
    all_projects = OwnershipStats.list_projects_for_organization(id)
    all_people = OwnershipStats.list_people_for_organization(id)
    all_domains = OwnershipStats.list_domains_for_organization(id)

    {:ok,
     socket
     |> assign(:page_title, org.display_name || org.name)
     |> assign(:org, org)
     |> assign(:stats, stats)
     |> assign(:all_projects, all_projects)
     |> assign(:all_people, all_people)
     |> assign(:all_domains, all_domains)
     |> assign(:projects, all_projects)
     |> assign(:people, all_people)
     |> assign(:domains, all_domains)
     |> assign(:current_tab, "projects")
     |> assign(:search_query, "")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = Map.get(params, "tab", "projects")
    {:noreply, assign(socket, :current_tab, tab)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    search_term = String.downcase(query)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:projects, filter_projects(socket.assigns.all_projects, search_term))
     |> assign(:people, filter_people(socket.assigns.all_people, search_term))
     |> assign(:domains, filter_domains(socket.assigns.all_domains, search_term))}
  end

  defp filter_projects(projects, ""), do: projects

  defp filter_projects(projects, term) do
    Enum.filter(projects, fn p ->
      String.contains?(String.downcase(p.name), term) ||
        (p.display_name && String.contains?(String.downcase(p.display_name), term)) ||
        (p.description && String.contains?(String.downcase(p.description), term))
    end)
  end

  defp filter_people(people, ""), do: people

  defp filter_people(people, term) do
    Enum.filter(people, fn p ->
      full_name = "#{p.first_name} #{p.last_name}" |> String.downcase()

      String.contains?(full_name, term) ||
        (p.title && String.contains?(String.downcase(p.title), term)) ||
        (p.email && String.contains?(String.downcase(p.email), term))
    end)
  end

  defp filter_domains(domains, ""), do: domains

  defp filter_domains(domains, term) do
    Enum.filter(domains, fn d ->
      String.contains?(String.downcase(d.name), term)
    end)
  end
end
