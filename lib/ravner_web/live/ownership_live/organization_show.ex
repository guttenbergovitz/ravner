defmodule RavnerWeb.OwnershipLive.OrganizationShow do
  use RavnerWeb, :live_view

  alias Ravner.Accounts
  alias Ravner.Accounts.ScopeResolver
  alias Ravner.Inventory
  alias Ravner.Inventory.OwnershipStats
  import RavnerWeb.DomainComponents, only: [governance_audit_trail: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns[:current_scope]

    if scope && not ScopeResolver.can_view_organization?(scope, id) do
      {:ok,
       socket
       |> put_flash(:error, "You do not have permission to view this organization.")
       |> push_navigate(to: ~p"/ownership")}
    else
      org = Inventory.get_organization!(id)
      stats = OwnershipStats.organization_stats(id)
      all_projects = OwnershipStats.list_projects_for_organization(id)
      all_people = OwnershipStats.list_people_for_organization(id)
      all_domains = OwnershipStats.list_domains_for_organization(id)
      people_options = Inventory.list_people()
      versions = Inventory.list_organization_versions(id)
      can_manage? = is_nil(scope) or ScopeResolver.can_manage_organization?(scope, org.id)

      can_delegate_po? =
        is_nil(scope) or
          ScopeResolver.can_delegate_role?(scope, :product_owner, %{organization_id: org.id})

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
       |> assign(:people_options, people_options)
       |> assign(:people_search_query, "")
       |> assign(:filtered_people, people_options)
       |> assign(:versions, versions)
       |> assign(:current_tab, "projects")
       |> assign(:search_query, "")
       |> assign(:can_manage?, can_manage?)
       |> assign(:can_delegate_po?, can_delegate_po?)
       |> assign(:assigning_manager?, false)
       |> assign(:inviting_owner?, false)
       |> assign(:generated_invite_link, nil)
       |> assign(
         :invite_form,
         to_form(%{"email" => "", "name" => "", "project_id" => ""}, as: :invite)
       )}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = Map.get(params, "tab", "projects")

    socket =
      case tab do
        "audit" ->
          assign(socket, :versions, Inventory.list_organization_versions(socket.assigns.org.id))

        _ ->
          socket
      end

    {:noreply, assign(socket, :current_tab, tab)}
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
  def handle_event("open_invite_owner", _params, socket) do
    {:noreply,
     socket
     |> assign(:inviting_owner?, true)
     |> assign(:generated_invite_link, nil)
     |> assign(
       :invite_form,
       to_form(%{"email" => "", "name" => "", "project_id" => ""}, as: :invite)
     )}
  end

  @impl true
  def handle_event("close_invite_owner", _params, socket) do
    {:noreply,
     socket
     |> assign(:inviting_owner?, false)
     |> assign(:generated_invite_link, nil)}
  end

  @impl true
  def handle_event("send_owner_invite", %{"invite" => params}, socket) do
    actor = socket.assigns.current_scope.user
    email = Map.get(params, "email", "")
    name = Map.get(params, "name", "")
    project_id = parse_manager_id(Map.get(params, "project_id"))

    context = %{organization_id: socket.assigns.org.id}

    if ScopeResolver.can_delegate_role?(
         socket.assigns.current_scope,
         :product_owner,
         context
       ) do
      invite_attrs = %{
        "email" => email,
        "role" => "product_owner"
      }

      case Accounts.create_invite(invite_attrs, actor.id, actor: actor) do
        {:ok, invite} ->
          invite_link =
            Phoenix.VerifiedRoutes.url(socket, ~p"/users/invite/#{invite.token}")

          if project_id do
            project = Inventory.get_project!(project_id)

            person_attrs = %{
              first_name: if(name != "", do: name, else: email),
              last_name: "(Invited Product Owner)",
              email: email
            }

            case Inventory.create_person(person_attrs, actor: actor) do
              {:ok, person} ->
                Inventory.create_project_role(
                  %{
                    project_id: project.id,
                    person_id: person.id,
                    role: :product_owner
                  },
                  actor: actor
                )

              _ ->
                :ok
            end
          end

          {:noreply,
           socket
           |> assign(:generated_invite_link, invite_link)
           |> put_flash(:info, "Invitation created for Product Owner #{email}.")}

        {:error, :forbidden} ->
          {:noreply,
           put_flash(socket, :error, "You do not have permission to invite product owners.")}

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
  def handle_event("assign_company_manager", %{"manager_id" => manager_id_param}, socket) do
    manager_id = parse_manager_id(manager_id_param)
    actor = socket.assigns.current_scope.user

    case Inventory.assign_organization_manager(socket.assigns.org, manager_id, actor: actor) do
      {:ok, updated} ->
        org = Inventory.get_organization!(updated.id)
        stats = OwnershipStats.organization_stats(org.id)
        versions = Inventory.list_organization_versions(org.id)

        {:noreply,
         socket
         |> assign(:org, org)
         |> assign(:stats, stats)
         |> assign(:versions, versions)
         |> assign(:assigning_manager?, false)
         |> assign(:people_search_query, "")
         |> assign(:filtered_people, socket.assigns.people_options)
         |> put_flash(:info, "Company manager updated successfully")}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:assigning_manager?, false)
         |> put_flash(:error, "You do not have permission to assign the company manager.")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:assigning_manager?, false)
         |> put_flash(:error, "Failed to update company manager.")}
    end
  end

  @impl true
  def handle_event("quick_unassign_company_manager", _params, socket) do
    actor = socket.assigns.current_scope.user

    case Inventory.assign_organization_manager(socket.assigns.org, nil, actor: actor) do
      {:ok, updated} ->
        org = Inventory.get_organization!(updated.id)
        stats = OwnershipStats.organization_stats(org.id)
        versions = Inventory.list_organization_versions(org.id)

        {:noreply,
         socket
         |> assign(:org, org)
         |> assign(:stats, stats)
         |> assign(:versions, versions)
         |> put_flash(:info, "Company manager unassigned")}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to update company manager.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unassign company manager.")}
    end
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

  defp parse_manager_id(param) when param in ["", "none", nil], do: nil
  defp parse_manager_id(id) when is_integer(id), do: id

  defp parse_manager_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> int
      :error -> nil
    end
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
