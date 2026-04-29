defmodule RavnerWeb.AdminLive.ProjectLive.Show do
  use RavnerWeb, :live_view

  alias Ravner.Inventory

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    project = Inventory.get_project!(id)
    roles = Inventory.list_project_roles(project.id)

    {:noreply,
     socket
     |> assign(:page_title, project.name)
     |> assign(:project, project)
     |> assign(:roles, roles)}
  end
end
