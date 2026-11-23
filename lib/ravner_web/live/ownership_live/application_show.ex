defmodule RavnerWeb.OwnershipLive.ApplicationShow do
  @moduledoc """
  Dedicated management view for an individual Application / Digital Asset workload.
  Supports editing metadata, attaching/detaching domains, provisioning datastores,
  linking external services, evaluating regulatory architecture constraints,
  and reviewing paper trail audit history.
  """
  use RavnerWeb, :live_view

  alias Ravner.Accounts.ScopeResolver
  alias Ravner.Domains
  alias Ravner.Inventory
  alias Ravner.Inventory.ArchitectureConstraint
  alias Ravner.Inventory.Datastore

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns[:current_scope]
    app = Inventory.get_application!(id)

    can_manage? =
      is_nil(scope) or scope.admin? or scope.editor? or
        (app.project_id && ScopeResolver.can_manage_project?(scope, app.project_id))

    hosting_environments = Inventory.list_hosting_environments()
    all_services = Inventory.list_external_services()
    all_value_streams = Inventory.list_value_streams()
    all_capabilities = Inventory.list_business_capabilities()
    candidate_domains = Domains.list_domains_filtered_all()
    versions = Inventory.list_application_versions(app.id)

    {:ok,
     socket
     |> assign(:page_title, app.name)
     |> assign(:app, app)
     |> assign(:can_manage?, can_manage?)
     |> assign(:hosting_environments, hosting_environments)
     |> assign(:all_services, all_services)
     |> assign(:all_value_streams, all_value_streams)
     |> assign(:all_capabilities, all_capabilities)
     |> assign(:candidate_domains, candidate_domains)
     |> assign(:versions, versions)
     |> assign(:current_tab, "overview")
     # Modals state
     |> assign(:editing_metadata?, false)
     |> assign(:adding_datastore?, false)
     |> assign(:adding_domain?, false)
     |> assign(:linking_service?, false)
     |> assign(:adding_constraint?, false)
     |> assign(:linking_value_stream?, false)
     |> assign(:linking_capability?, false)
     |> assign(:domain_search_query, "")
     # Forms
     |> assign_app_edit_form(app)
     |> assign_datastore_form()
     |> assign_constraint_form()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = Map.get(params, "tab", "overview")
    {:noreply, assign(socket, :current_tab, tab)}
  end

  # ─── Modals Visibility Events ───────────────────────────────────────────────

  @impl true
  def handle_event("open_edit_metadata", _params, socket) do
    {:noreply, assign(socket, :editing_metadata?, true)}
  end

  @impl true
  def handle_event("close_edit_metadata", _params, socket) do
    {:noreply, assign(socket, :editing_metadata?, false)}
  end

  @impl true
  def handle_event("open_add_datastore", _params, socket) do
    {:noreply, assign(socket, :adding_datastore?, true)}
  end

  @impl true
  def handle_event("close_add_datastore", _params, socket) do
    {:noreply, assign(socket, :adding_datastore?, false)}
  end

  @impl true
  def handle_event("open_add_domain", _params, socket) do
    {:noreply, assign(socket, :adding_domain?, true)}
  end

  @impl true
  def handle_event("close_add_domain", _params, socket) do
    {:noreply, assign(socket, :adding_domain?, false)}
  end

  @impl true
  def handle_event("open_link_service", _params, socket) do
    {:noreply, assign(socket, :linking_service?, true)}
  end

  @impl true
  def handle_event("close_link_service", _params, socket) do
    {:noreply, assign(socket, :linking_service?, false)}
  end

  @impl true
  def handle_event("open_add_constraint", _params, socket) do
    {:noreply, assign(socket, :adding_constraint?, true)}
  end

  @impl true
  def handle_event("close_add_constraint", _params, socket) do
    {:noreply, assign(socket, :adding_constraint?, false)}
  end

  @impl true
  def handle_event("open_link_value_stream", _params, socket) do
    {:noreply, assign(socket, :linking_value_stream?, true)}
  end

  @impl true
  def handle_event("close_link_value_stream", _params, socket) do
    {:noreply, assign(socket, :linking_value_stream?, false)}
  end

  @impl true
  def handle_event("open_link_capability", _params, socket) do
    {:noreply, assign(socket, :linking_capability?, true)}
  end

  @impl true
  def handle_event("close_link_capability", _params, socket) do
    {:noreply, assign(socket, :linking_capability?, false)}
  end

  # ─── Form Handlers & Mutations ─────────────────────────────────────────────

  @impl true
  def handle_event("validate_app_edit", %{"application" => params}, socket) do
    form =
      socket.assigns.app_edit_form
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, :app_edit_form, form)}
  end

  @impl true
  def handle_event("save_app_edit", %{"application" => params}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app

      case Inventory.update_application(app, params, actor: actor) do
        {:ok, updated_app} ->
          refreshed = Inventory.get_application!(updated_app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> assign(:editing_metadata?, false)
           |> assign_app_edit_form(refreshed)
           |> assign(:versions, Inventory.list_application_versions(refreshed.id))
           |> put_flash(:info, "Application details updated successfully.")}

        {:error, changeset} ->
          {:noreply, assign(socket, :app_edit_form, to_form(changeset, as: :application))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized to edit this application.")}
    end
  end

  @impl true
  def handle_event("search_domain_candidates", %{"query" => query}, socket) do
    {:noreply, assign(socket, :domain_search_query, query)}
  end

  @impl true
  def handle_event("attach_domain", %{"domain_id" => domain_id}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app
      domain = Domains.get_domain!(domain_id)

      case Domains.update_domain(domain, %{application_id: app.id}, actor: actor) do
        {:ok, _updated} ->
          refreshed = Inventory.get_application!(app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> assign(:adding_domain?, false)
           |> put_flash(:info, "Domain #{domain.name} attached to #{app.name}.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to attach domain.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized.")}
    end
  end

  @impl true
  def handle_event("detach_domain", %{"domain_id" => domain_id}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app
      domain = Domains.get_domain!(domain_id)

      case Domains.update_domain(domain, %{application_id: nil}, actor: actor) do
        {:ok, _updated} ->
          refreshed = Inventory.get_application!(app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> put_flash(:info, "Domain detached.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to detach domain.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized.")}
    end
  end

  @impl true
  def handle_event("save_datastore", %{"datastore" => params}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app

      params_with_app =
        params
        |> Map.put("application_id", app.id)
        |> then(fn p ->
          if Map.get(p, "slug", "") == "" do
            slug =
              p
              |> Map.get("name", "db")
              |> String.downcase()
              |> String.replace(~r/[^a-z0-9]+/, "-")
              |> String.trim("-")

            Map.put(p, "slug", "#{app.slug}-#{slug}")
          else
            p
          end
        end)

      case Inventory.create_datastore(params_with_app, actor: actor) do
        {:ok, _datastore} ->
          refreshed = Inventory.get_application!(app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> assign(:adding_datastore?, false)
           |> assign_datastore_form()
           |> put_flash(:info, "Datastore provisioned successfully.")}

        {:error, changeset} ->
          {:noreply, assign(socket, :datastore_form, to_form(changeset, as: :datastore))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized.")}
    end
  end

  @impl true
  def handle_event("delete_datastore", %{"id" => ds_id}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app
      ds = Inventory.get_datastore!(ds_id)

      case Inventory.delete_datastore(ds, actor: actor) do
        {:ok, _} ->
          refreshed = Inventory.get_application!(app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> put_flash(:info, "Datastore removed.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to remove datastore.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized.")}
    end
  end

  @impl true
  def handle_event("link_external_service", %{"service_id" => service_id}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app

      case Inventory.create_application_external_service(
             %{
               application_id: app.id,
               external_service_id: String.to_integer(service_id),
               integration_type: "api"
             },
             actor: actor
           ) do
        {:ok, _} ->
          refreshed = Inventory.get_application!(app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> assign(:linking_service?, false)
           |> put_flash(:info, "External service linked.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to link external service.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized.")}
    end
  end

  @impl true
  def handle_event("unlink_external_service", %{"service_id" => service_id}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app

      case Inventory.delete_application_external_service(
             app.id,
             String.to_integer(service_id),
             actor: actor
           ) do
        :ok ->
          refreshed = Inventory.get_application!(app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> put_flash(:info, "External service unlinked.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to unlink external service.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized.")}
    end
  end

  @impl true
  def handle_event("link_value_stream", %{"value_stream_id" => vs_id}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app

      case Inventory.create_application_value_stream(
             %{application_id: app.id, value_stream_id: String.to_integer(vs_id)},
             actor: actor
           ) do
        {:ok, _} ->
          refreshed = Inventory.get_application!(app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> assign(:linking_value_stream?, false)
           |> put_flash(:info, "Value stream linked.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to link value stream.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized.")}
    end
  end

  @impl true
  def handle_event("unlink_value_stream", %{"value_stream_id" => vs_id}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app

      case Inventory.delete_application_value_stream(
             app.id,
             String.to_integer(vs_id),
             actor: actor
           ) do
        :ok ->
          refreshed = Inventory.get_application!(app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> put_flash(:info, "Value stream unlinked.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to unlink value stream.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized.")}
    end
  end

  @impl true
  def handle_event("link_capability", %{"capability_id" => cap_id}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app

      case Inventory.create_application_capability(
             %{application_id: app.id, business_capability_id: String.to_integer(cap_id)},
             actor: actor
           ) do
        {:ok, _} ->
          refreshed = Inventory.get_application!(app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> assign(:linking_capability?, false)
           |> put_flash(:info, "Capability linked.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to link capability.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized.")}
    end
  end

  @impl true
  def handle_event("unlink_capability", %{"capability_id" => cap_id}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app

      case Inventory.delete_application_capability(
             app.id,
             String.to_integer(cap_id),
             actor: actor
           ) do
        :ok ->
          refreshed = Inventory.get_application!(app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> put_flash(:info, "Capability unlinked.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to unlink capability.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized.")}
    end
  end

  @impl true
  def handle_event("save_constraint", %{"architecture_constraint" => params}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app

      params_with_app = Map.put(params, "application_id", app.id)

      case Inventory.create_architecture_constraint(params_with_app, actor: actor) do
        {:ok, _} ->
          refreshed = Inventory.get_application!(app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> assign(:adding_constraint?, false)
           |> assign_constraint_form()
           |> put_flash(:info, "Architecture constraint policy registered.")}

        {:error, changeset} ->
          {:noreply,
           assign(socket, :constraint_form, to_form(changeset, as: :architecture_constraint))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized.")}
    end
  end

  @impl true
  def handle_event("delete_constraint", %{"id" => constraint_id}, socket) do
    if socket.assigns.can_manage? do
      actor = get_actor(socket)
      app = socket.assigns.app
      constraint = Inventory.get_architecture_constraint!(constraint_id)

      case Inventory.delete_architecture_constraint(constraint, actor: actor) do
        {:ok, _} ->
          refreshed = Inventory.get_application!(app.id)

          {:noreply,
           socket
           |> assign(:app, refreshed)
           |> put_flash(:info, "Policy constraint deleted.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete constraint.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized.")}
    end
  end

  # ─── Helpers ───────────────────────────────────────────────────────────────

  defp get_actor(socket) do
    if socket.assigns[:current_scope], do: socket.assigns.current_scope.user, else: nil
  end

  defp assign_app_edit_form(socket, app) do
    form =
      AshPhoenix.Form.for_update(app, :update,
        as: "application",
        actor: get_actor(socket)
      )
      |> to_form()

    assign(socket, :app_edit_form, form)
  end

  defp assign_datastore_form(socket) do
    form =
      AshPhoenix.Form.for_create(Datastore, :create,
        as: "datastore",
        actor: get_actor(socket)
      )
      |> to_form()

    assign(socket, :datastore_form, form)
  end

  defp assign_constraint_form(socket) do
    form =
      AshPhoenix.Form.for_create(ArchitectureConstraint, :create,
        as: "architecture_constraint",
        actor: get_actor(socket)
      )
      |> to_form()

    assign(socket, :constraint_form, form)
  end

  def filter_candidate_domains(domains, query, current_app_id) do
    q = String.downcase(String.trim(query || ""))

    domains
    |> Enum.reject(fn d -> d.application_id == current_app_id end)
    |> Enum.filter(fn d ->
      if q == "", do: true, else: String.contains?(String.downcase(d.name), q)
    end)
    |> Enum.take(8)
  end
end
