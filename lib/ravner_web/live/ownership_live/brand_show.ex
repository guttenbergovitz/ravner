defmodule RavnerWeb.OwnershipLive.BrandShow do
  use RavnerWeb, :live_view

  alias Ravner.Accounts
  alias Ravner.Accounts.ScopeResolver
  alias Ravner.Inventory
  alias Ravner.Inventory.OwnershipStats
  import RavnerWeb.DomainComponents, only: [governance_audit_trail: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns[:current_scope]

    if scope && not ScopeResolver.can_view_brand?(scope, id) do
      {:ok,
       socket
       |> put_flash(:error, "You do not have permission to view this brand.")
       |> push_navigate(to: ~p"/ownership")}
    else
      brand = Inventory.get_brand!(id)
      stats = OwnershipStats.brand_stats(id)
      all_organizations = OwnershipStats.list_organizations_for_brand(id)
      people_options = Inventory.list_people()
      versions = Inventory.list_brand_versions(id)
      can_manage? = is_nil(scope) or ScopeResolver.can_manage_brand?(scope, brand.id)

      can_delegate_manager? =
        is_nil(scope) or
          ScopeResolver.can_delegate_role?(scope, :organization_manager, %{brand_id: brand.id})

      {:ok,
       socket
       |> assign(:page_title, brand.display_name || brand.name)
       |> assign(:brand, brand)
       |> assign(:stats, stats)
       |> assign(:all_organizations, all_organizations)
       |> assign(:organizations, all_organizations)
       |> assign(:people_options, people_options)
       |> assign(:people_search_query, "")
       |> assign(:filtered_people, people_options)
       |> assign(:versions, versions)
       |> assign(:projects, [])
       |> assign(:people, [])
       |> assign(:domains, [])
       |> assign(:current_tab, "organizations")
       |> assign(:search_query, "")
       |> assign(:can_manage?, can_manage?)
       |> assign(:can_delegate_manager?, can_delegate_manager?)
       |> assign(:assigning_manager?, false)
       |> assign(:inviting_manager?, false)
       |> assign(:generated_invite_link, nil)
       |> assign(
         :invite_form,
         to_form(%{"email" => "", "name" => "", "organization_id" => ""}, as: :invite)
       )}
    end
  end

  @impl true
  def handle_params(%{"tab" => tab} = _params, _url, socket) do
    socket =
      case tab do
        "projects" ->
          assign(
            socket,
            :projects,
            OwnershipStats.list_projects_for_brand(socket.assigns.brand.id)
          )

        "people" ->
          assign(socket, :people, OwnershipStats.list_people_for_brand(socket.assigns.brand.id))

        "domains" ->
          assign(socket, :domains, OwnershipStats.list_domains_for_brand(socket.assigns.brand.id))

        "audit" ->
          assign(socket, :versions, Inventory.list_brand_versions(socket.assigns.brand.id))

        _ ->
          socket
      end

    {:noreply, assign(socket, :current_tab, tab)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :current_tab, "organizations")}
  end

  @impl true
  def handle_event("open_assign_manager", _params, socket) do
    {:noreply,
     socket
     |> assign(:assigning_manager?, true)
     |> assign(:people_search_query, "")
     |> assign(:filtered_people, socket.assigns.people_options)}
  end

  @impl true
  def handle_event("close_assign_manager", _params, socket) do
    {:noreply,
     socket
     |> assign(:assigning_manager?, false)
     |> assign(:people_search_query, "")
     |> assign(:filtered_people, socket.assigns.people_options)}
  end

  @impl true
  def handle_event("open_invite_manager", _params, socket) do
    {:noreply,
     socket
     |> assign(:inviting_manager?, true)
     |> assign(:generated_invite_link, nil)
     |> assign(
       :invite_form,
       to_form(%{"email" => "", "name" => "", "organization_id" => ""}, as: :invite)
     )}
  end

  @impl true
  def handle_event("close_invite_manager", _params, socket) do
    {:noreply,
     socket
     |> assign(:inviting_manager?, false)
     |> assign(:generated_invite_link, nil)}
  end

  @impl true
  def handle_event("send_manager_invite", %{"invite" => params}, socket) do
    actor = socket.assigns.current_scope.user
    email = Map.get(params, "email", "")
    name = Map.get(params, "name", "")
    org_id = parse_manager_id(Map.get(params, "organization_id"))

    context = %{brand_id: socket.assigns.brand.id, organization_id: org_id}

    if ScopeResolver.can_delegate_role?(
         socket.assigns.current_scope,
         :organization_manager,
         context
       ) do
      invite_attrs = %{
        "email" => email,
        "role" => "organization_manager"
      }

      case Accounts.create_invite(invite_attrs, actor.id, actor: actor) do
        {:ok, invite} ->
          invite_link =
            Phoenix.VerifiedRoutes.url(socket, ~p"/users/invite/#{invite.token}")

          if org_id do
            org = Inventory.get_organization!(org_id)

            person_attrs = %{
              first_name: if(name != "", do: name, else: email),
              last_name: "(Invited Manager)",
              email: email
            }

            case Inventory.create_person(person_attrs, actor: actor) do
              {:ok, person} ->
                Inventory.assign_organization_manager(org, person.id, actor: actor)

              _ ->
                :ok
            end
          end

          {:noreply,
           socket
           |> assign(:generated_invite_link, invite_link)
           |> put_flash(:info, "Invitation created for #{email}.")}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, "You do not have permission to invite managers.")}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, assign(socket, :invite_form, to_form(cs, as: :invite))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not create invite.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Authorization denied.")}
    end
  end

  @impl true
  def handle_event("assign_brand_manager", %{"manager_id" => manager_id_param}, socket) do
    manager_id = parse_manager_id(manager_id_param)
    actor = socket.assigns.current_scope.user

    case Inventory.assign_brand_manager(socket.assigns.brand, manager_id, actor: actor) do
      {:ok, updated} ->
        brand = Inventory.get_brand!(updated.id)
        stats = OwnershipStats.brand_stats(brand.id)
        versions = Inventory.list_brand_versions(brand.id)

        {:noreply,
         socket
         |> assign(:brand, brand)
         |> assign(:stats, stats)
         |> assign(:versions, versions)
         |> assign(:assigning_manager?, false)
         |> assign(:people_search_query, "")
         |> assign(:filtered_people, socket.assigns.people_options)
         |> put_flash(:info, "Brand manager updated successfully")}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:assigning_manager?, false)
         |> put_flash(:error, "You do not have permission to assign the brand manager.")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:assigning_manager?, false)
         |> put_flash(:error, "Failed to update brand manager.")}
    end
  end

  @impl true
  def handle_event("quick_unassign_brand_manager", _params, socket) do
    actor = socket.assigns.current_scope.user

    case Inventory.assign_brand_manager(socket.assigns.brand, nil, actor: actor) do
      {:ok, updated} ->
        brand = Inventory.get_brand!(updated.id)
        stats = OwnershipStats.brand_stats(brand.id)
        versions = Inventory.list_brand_versions(brand.id)

        {:noreply,
         socket
         |> assign(:brand, brand)
         |> assign(:stats, stats)
         |> assign(:versions, versions)
         |> put_flash(:info, "Brand manager unassigned")}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to update brand manager.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unassign brand manager.")}
    end
  end

  @impl true
  def handle_event("search_people", %{"query" => query}, socket) do
    search_term = String.downcase(query)

    {:noreply,
     socket
     |> assign(:people_search_query, query)
     |> assign(
       :filtered_people,
       filter_people(socket.assigns.people_options, search_term)
     )}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    search_term = String.downcase(query)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(
       :organizations,
       filter_organizations(socket.assigns.all_organizations, search_term)
     )}
  end

  defp parse_manager_id(param) when param in ["", "none", nil], do: nil
  defp parse_manager_id(id) when is_integer(id), do: id

  defp parse_manager_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> int
      :error -> nil
    end
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

  defp filter_organizations(orgs, ""), do: orgs

  defp filter_organizations(orgs, term) do
    Enum.filter(orgs, fn org ->
      String.contains?(String.downcase(org.name), term) ||
        (org.display_name && String.contains?(String.downcase(org.display_name), term)) ||
        (org.country && String.contains?(String.downcase(org.country), term))
    end)
  end
end
