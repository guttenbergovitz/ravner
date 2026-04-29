defmodule RavnerWeb.AdminLive.ProjectLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.Project

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Projects")
     |> assign(:orgs, Inventory.list_organizations())
     |> assign(:people, Inventory.list_people())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Projects")
    |> assign(:projects, Inventory.list_projects())
    |> assign(:project, nil)
    |> assign(:roles, [])
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Project")
    |> assign(:projects, Inventory.list_projects())
    |> assign(:project, %Project{})
    |> assign(:roles, [])
    |> assign(:form, to_form(Inventory.change_project(%Project{}), as: :project))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    project = Inventory.get_project!(id)

    socket
    |> assign(:page_title, "Edit Project")
    |> assign(:projects, Inventory.list_projects())
    |> assign(:project, project)
    |> assign(:roles, Inventory.list_project_roles(project.id))
    |> assign(:form, to_form(Inventory.change_project(project), as: :project))
  end

  @impl true
  def handle_event("save", %{"project" => attrs}, socket) do
    project = socket.assigns.project
    project_id = project && project.id

    result =
      if project_id do
        Inventory.update_project(project, attrs)
      else
        Inventory.create_project(attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project saved")
         |> push_patch(to: ~p"/admin/projects")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :project))}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    Inventory.delete_project(Inventory.get_project!(id))

    {:noreply,
     socket
     |> put_flash(:info, "Project deleted")
     |> assign(:projects, Inventory.list_projects())}
  end

  @impl true
  def handle_event("add_role", %{"project_role" => attrs}, socket) do
    attrs = Map.put(attrs, "project_id", socket.assigns.project.id)

    case Inventory.create_project_role(attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Role added")
         |> assign(:roles, Inventory.list_project_roles(socket.assigns.project.id))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add role (already exists?)")}
    end
  end

  @impl true
  def handle_event("delete_role", %{"id" => id}, socket) do
    Inventory.delete_project_role(Inventory.get_project_role!(id))

    {:noreply,
     socket
     |> assign(:roles, Inventory.list_project_roles(socket.assigns.project.id))}
  end
end
