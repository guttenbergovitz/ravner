defmodule RavnerWeb.OwnershipLive.Landscape do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.Application
  alias Ravner.Inventory.ValueStream
  alias Ravner.Inventory.BusinessCapability

  @impl true
  def mount(_params, _session, socket) do
    applications = Inventory.list_applications()
    value_streams = Inventory.list_value_streams()
    capabilities = Inventory.list_business_capabilities()
    hosting_environments = Inventory.list_hosting_environments()
    projects = Inventory.list_projects()
    brands = Inventory.list_brands()
    people = Inventory.list_people()

    can_manage? =
      case socket.assigns[:current_scope] do
        nil -> true
        scope -> scope.admin? or scope.editor?
      end

    {:ok,
     socket
     |> assign(:page_title, "Enterprise Digital Landscape")
     |> assign(:applications, applications)
     |> assign(:value_streams, value_streams)
     |> assign(:capabilities, capabilities)
     |> assign(:hosting_environments, hosting_environments)
     |> assign(:projects, projects)
     |> assign(:brands, brands)
     |> assign(:people, people)
     |> assign(:can_manage?, can_manage?)
     |> assign(:current_tab, "catalog")
     |> assign(:creating_app?, false)
     |> assign(:filter_type, "all")
     |> assign(:filter_criticality, "all")
     |> assign(:search_query, "")
     # Value Stream CRUD state
     |> assign(:creating_value_stream?, false)
     |> assign(:editing_value_stream, nil)
     # Capability CRUD state
     |> assign(:creating_capability?, false)
     |> assign(:editing_capability, nil)
     # App creation multi-select
     |> assign(:selected_value_streams, [])
     |> assign(:selected_capabilities, [])
     |> assign_form()
     |> assign_value_stream_form()
     |> assign_capability_form()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign(:current_tab, Map.get(params, "tab", "catalog"))
     |> assign(:filter_type, Map.get(params, "type", "all"))
     |> assign(:filter_criticality, Map.get(params, "criticality", "all"))}
  end

  @impl true
  def handle_event("open_create_app", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating_app?, true)
     |> assign(:selected_value_streams, [])
     |> assign(:selected_capabilities, [])
     |> assign_form()}
  end

  @impl true
  def handle_event("close_create_app", _params, socket) do
    {:noreply, assign(socket, :creating_app?, false)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :search_query, query)}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :filter_type, type)}
  end

  @impl true
  def handle_event("filter_criticality", %{"criticality" => criticality}, socket) do
    {:noreply, assign(socket, :filter_criticality, criticality)}
  end

  @impl true
  def handle_event("toggle_app_value_stream", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    current = socket.assigns.selected_value_streams

    updated =
      if id in current,
        do: List.delete(current, id),
        else: [id | current]

    {:noreply, assign(socket, :selected_value_streams, updated)}
  end

  @impl true
  def handle_event("toggle_app_capability", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    current = socket.assigns.selected_capabilities

    updated =
      if id in current,
        do: List.delete(current, id),
        else: [id | current]

    {:noreply, assign(socket, :selected_capabilities, updated)}
  end

  @impl true
  def handle_event("save_app", %{"application" => app_params}, socket) do
    actor = if socket.assigns[:current_scope], do: socket.assigns.current_scope.user, else: nil

    # Auto-generate slug if missing
    params =
      if Map.get(app_params, "slug", "") == "" do
        slug =
          app_params
          |> Map.get("name", "app")
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        Map.put(app_params, "slug", slug)
      else
        app_params
      end

    case Inventory.create_application(params, actor: actor) do
      {:ok, app} ->
        # Create VS links
        for vs_id <- socket.assigns.selected_value_streams do
          Inventory.create_application_value_stream(
            %{application_id: app.id, value_stream_id: vs_id},
            actor: actor
          )
        end

        # Create capability links
        for cap_id <- socket.assigns.selected_capabilities do
          Inventory.create_application_capability(
            %{application_id: app.id, business_capability_id: cap_id},
            actor: actor
          )
        end

        {:noreply,
         socket
         |> put_flash(:info, "Application created successfully.")
         |> assign(:creating_app?, false)
         |> assign(:selected_value_streams, [])
         |> assign(:selected_capabilities, [])
         |> assign(:applications, Inventory.list_applications())
         |> assign(:value_streams, Inventory.list_value_streams())
         |> assign(:capabilities, Inventory.list_business_capabilities())
         |> assign_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # ─── Value Stream CRUD Events ───────────────────────────────────────────────

  @impl true
  def handle_event("open_create_value_stream", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating_value_stream?, true)
     |> assign(:editing_value_stream, nil)
     |> assign_value_stream_form()}
  end

  @impl true
  def handle_event("close_value_stream_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating_value_stream?, false)
     |> assign(:editing_value_stream, nil)}
  end

  @impl true
  def handle_event("edit_value_stream", %{"id" => id}, socket) do
    vs = Inventory.get_value_stream!(id)

    {:noreply,
     socket
     |> assign(:editing_value_stream, vs)
     |> assign(:creating_value_stream?, false)
     |> assign_value_stream_form(vs)}
  end

  @impl true
  def handle_event("save_value_stream", %{"value_stream" => params}, socket) do
    actor = get_actor(socket)

    # Auto-generate slug if empty
    params =
      if Map.get(params, "slug", "") == "" do
        slug =
          params
          |> Map.get("name", "vs")
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        Map.put(params, "slug", slug)
      else
        params
      end

    result =
      if socket.assigns.editing_value_stream do
        Inventory.update_value_stream(socket.assigns.editing_value_stream, params, actor: actor)
      else
        Inventory.create_value_stream(params, actor: actor)
      end

    case result do
      {:ok, _vs} ->
        {:noreply,
         socket
         |> assign(:creating_value_stream?, false)
         |> assign(:editing_value_stream, nil)
         |> assign(:value_streams, Inventory.list_value_streams())
         |> assign_value_stream_form()
         |> put_flash(:info, "Value stream saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :value_stream_form, to_form(changeset, as: :value_stream))}
    end
  end

  @impl true
  def handle_event("delete_value_stream", %{"id" => id}, socket) do
    actor = get_actor(socket)
    vs = Inventory.get_value_stream!(id)

    case Inventory.delete_value_stream(vs, actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:value_streams, Inventory.list_value_streams())
         |> put_flash(:info, "Value stream deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete value stream.")}
    end
  end

  # ─── Capability CRUD Events ────────────────────────────────────────────────

  @impl true
  def handle_event("open_create_capability", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating_capability?, true)
     |> assign(:editing_capability, nil)
     |> assign_capability_form()}
  end

  @impl true
  def handle_event("close_capability_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating_capability?, false)
     |> assign(:editing_capability, nil)}
  end

  @impl true
  def handle_event("edit_capability", %{"id" => id}, socket) do
    cap = Inventory.get_business_capability!(id)

    {:noreply,
     socket
     |> assign(:editing_capability, cap)
     |> assign(:creating_capability?, false)
     |> assign_capability_form(cap)}
  end

  @impl true
  def handle_event("save_capability", %{"business_capability" => params}, socket) do
    actor = get_actor(socket)

    # Auto-generate slug if empty
    params =
      if Map.get(params, "slug", "") == "" do
        slug =
          params
          |> Map.get("name", "cap")
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        Map.put(params, "slug", slug)
      else
        params
      end

    result =
      if socket.assigns.editing_capability do
        Inventory.update_business_capability(
          socket.assigns.editing_capability,
          params,
          actor: actor
        )
      else
        Inventory.create_business_capability(params, actor: actor)
      end

    case result do
      {:ok, _cap} ->
        {:noreply,
         socket
         |> assign(:creating_capability?, false)
         |> assign(:editing_capability, nil)
         |> assign(:capabilities, Inventory.list_business_capabilities())
         |> assign_capability_form()
         |> put_flash(:info, "Business capability saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :capability_form, to_form(changeset, as: :business_capability))}
    end
  end

  @impl true
  def handle_event("delete_capability", %{"id" => id}, socket) do
    actor = get_actor(socket)
    cap = Inventory.get_business_capability!(id)

    case Inventory.delete_business_capability(cap, actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:capabilities, Inventory.list_business_capabilities())
         |> put_flash(:info, "Business capability deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete capability.")}
    end
  end

  # ─── Form Helpers ──────────────────────────────────────────────────────────

  defp get_actor(socket) do
    if socket.assigns[:current_scope], do: socket.assigns.current_scope.user, else: nil
  end

  defp assign_form(socket) do
    form =
      AshPhoenix.Form.for_create(Application, :create,
        as: "application",
        actor:
          if(socket.assigns[:current_scope], do: socket.assigns.current_scope.user, else: nil)
      )
      |> to_form()

    assign(socket, :form, form)
  end

  defp assign_value_stream_form(socket, vs \\ nil) do
    form =
      if vs do
        AshPhoenix.Form.for_update(vs, :update, as: "value_stream", actor: get_actor(socket))
      else
        AshPhoenix.Form.for_create(ValueStream, :create,
          as: "value_stream",
          actor: get_actor(socket)
        )
      end
      |> to_form()

    assign(socket, :value_stream_form, form)
  end

  defp assign_capability_form(socket, cap \\ nil) do
    form =
      if cap do
        AshPhoenix.Form.for_update(cap, :update,
          as: "business_capability",
          actor: get_actor(socket)
        )
      else
        AshPhoenix.Form.for_create(BusinessCapability, :create,
          as: "business_capability",
          actor: get_actor(socket)
        )
      end
      |> to_form()

    assign(socket, :capability_form, form)
  end

  defp filter_apps(applications, search, type, criticality) do
    applications
    |> Enum.filter(fn app ->
      matches_search? =
        if search == "" do
          true
        else
          pattern = String.downcase(search)

          String.contains?(String.downcase(app.name || ""), pattern) or
            String.contains?(String.downcase(app.slug || ""), pattern)
        end

      matches_type? =
        type == "all" or app.app_type == type

      matches_crit? =
        criticality == "all" or app.criticality == criticality

      matches_search? and matches_type? and matches_crit?
    end)
  end

  # Matrix helper: find apps at intersection of value stream and capability
  defp find_apps_at_intersection(vs, cap) do
    vs_ids = MapSet.new(Enum.map(vs.applications || [], & &1.id))
    cap_ids = MapSet.new(Enum.map(cap.applications || [], & &1.id))
    common = MapSet.intersection(vs_ids, cap_ids)
    Enum.filter(vs.applications || [], &MapSet.member?(common, &1.id))
  end
end
