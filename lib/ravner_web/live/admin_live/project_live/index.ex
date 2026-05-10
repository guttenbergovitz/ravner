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
    |> assign(
      :form,
      AshPhoenix.Form.for_create(Project, :create,
        as: "project",
        actor: socket.assigns.current_scope.user
      )
      |> to_form()
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    project = Inventory.get_project!(id)

    socket
    |> assign(:page_title, "Edit Project")
    |> assign(:projects, Inventory.list_projects())
    |> assign(:project, project)
    |> assign(:roles, Inventory.list_project_roles(project.id))
    |> assign(:repos, Inventory.list_project_repositories(project.id))
    |> assign(
      :form,
      AshPhoenix.Form.for_update(project, :update,
        as: "project",
        actor: socket.assigns.current_scope.user
      )
      |> to_form()
    )
  end

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("save", %{"project" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project saved")
         |> push_patch(to: ~p"/admin/projects")}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    case Inventory.delete_project(Inventory.get_project!(id), actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project deleted")
         |> assign(:projects, Inventory.list_projects())}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete project.")}
    end
  end

  @impl true
  def handle_event("add_role", %{"project_role" => attrs}, socket) do
    attrs = Map.put(attrs, "project_id", socket.assigns.project.id)
    actor = socket.assigns.current_scope.user

    case Inventory.create_project_role(attrs, actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Role added")
         |> assign(:roles, Inventory.list_project_roles(socket.assigns.project.id))}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add role (already exists?)")}
    end
  end

  @impl true
  def handle_event("delete_role", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    case Inventory.delete_project_role(Inventory.get_project_role!(id), actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:roles, Inventory.list_project_roles(socket.assigns.project.id))}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete role.")}
    end
  end

  @impl true
  def handle_event("add_repo", %{"project_repository" => attrs}, socket) do
    attrs = Map.put(attrs, "project_id", socket.assigns.project.id)
    actor = socket.assigns.current_scope.user

    case Inventory.create_project_repository(attrs, actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Repository added")
         |> assign(:repos, Inventory.list_project_repositories(socket.assigns.project.id))}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add repository")}
    end
  end

  @impl true
  def handle_event("delete_repo", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    case Inventory.delete_project_repository(Inventory.get_project_repository!(id), actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:repos, Inventory.list_project_repositories(socket.assigns.project.id))}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete repository.")}
    end
  end
end
