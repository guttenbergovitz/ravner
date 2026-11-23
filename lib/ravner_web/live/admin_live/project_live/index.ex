defmodule RavnerWeb.AdminLive.ProjectLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.Project
  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:current_scope]

    {:ok,
     socket
     |> assign(:page_title, "Projects")
     |> assign(:orgs, Inventory.list_organizations(scope: scope))
     |> assign(:people, Inventory.list_people(scope: scope))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    scope = socket.assigns[:current_scope]

    can_create? =
      scope &&
        (scope.admin? or scope.editor? or
           scope.role in [:brand_manager, :organization_manager])

    if can_create? do
      socket
      |> assign(:page_title, "New Project")
      |> assign(:project, %Project{})
      |> assign(:roles, [])
      |> assign(:repos, [])
      |> assign(:stats, nil)
      |> assign(:form, nil)
      |> assign(
        :form,
        AshPhoenix.Form.for_create(Project, :create,
          as: "project",
          actor: socket.assigns.current_scope.user
        )
        |> to_form()
      )
    else
      socket
      |> put_flash(:error, "You do not have permission to create projects.")
      |> push_navigate(to: ~p"/ownership")
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns[:current_scope]
    project = Inventory.get_project!(id)

    if scope && not Ravner.Accounts.ScopeResolver.can_manage_project?(scope, project) do
      socket
      |> put_flash(:error, "You do not have permission to manage this project.")
      |> push_navigate(to: ~p"/ownership/projects/#{project.id}")
    else
      socket
      |> assign(:page_title, "Edit Project")
      |> assign(:project, project)
      |> assign(:roles, Inventory.list_project_roles(project.id))
      |> assign(:repos, Inventory.list_project_repositories(project.id))
      |> assign(:stats, OwnershipStats.project_stats(id))
      |> assign(:form, nil)
      |> assign(
        :form,
        AshPhoenix.Form.for_update(project, :update,
          as: "project",
          actor: socket.assigns.current_scope.user
        )
        |> to_form()
      )
    end
  end

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("save", %{"project" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project saved")
         |> push_navigate(to: ~p"/ownership/projects/#{project.id}")}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  @impl true
  def handle_event("delete", _, socket) do
    project = socket.assigns.project
    actor = socket.assigns.current_scope.user

    case Inventory.delete_project(project, actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project deleted")
         |> push_navigate(to: ~p"/ownership")}

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
