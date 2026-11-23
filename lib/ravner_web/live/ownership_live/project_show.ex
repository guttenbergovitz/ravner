defmodule RavnerWeb.OwnershipLive.ProjectShow do
  use RavnerWeb, :live_view

  alias Ravner.Accounts.ScopeResolver
  alias Ravner.Inventory
  alias Ravner.Inventory.OwnershipStats
  alias Ravner.Integrations.VCS
  alias RavnerWeb.VcsCoordinator
  import RavnerWeb.DomainComponents, only: [format_relative_timestamp: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns[:current_scope]

    if scope && not ScopeResolver.can_view_project?(scope, id) do
      {:ok,
       socket
       |> put_flash(:error, "You do not have permission to view this project.")
       |> push_navigate(to: ~p"/ownership")}
    else
      project = Inventory.get_project!(id)
      stats = OwnershipStats.project_stats(id)
      all_team = OwnershipStats.list_team_for_project(id)
      all_domains = OwnershipStats.list_domains_for_project(id)
      all_repositories = Inventory.list_project_repositories(id)
      risk_posture = Ravner.Governance.RiskScore.calculate_for_project(project.id)
      active_vcs = VCS.safe_active_vcs("bitbucket")
      can_manage? = is_nil(scope) or ScopeResolver.can_manage_project?(scope, project.id)

      {:ok,
       socket
       |> assign(:page_title, project.display_name || project.name)
       |> assign(:project, project)
       |> assign(:stats, stats)
       |> assign(:risk_posture, risk_posture)
       |> assign(:all_team, all_team)
       |> assign(:all_domains, all_domains)
       |> assign(:all_repositories, all_repositories)
       |> assign(:team, all_team)
       |> assign(:domains, all_domains)
       |> assign(:repositories, all_repositories)
       |> assign(:current_tab, "team")
       |> assign(:search_query, "")
       |> assign(:can_manage?, can_manage?)
       # Domain assignment modal state
       |> assign(:assigning_domain?, false)
       |> assign(:candidate_domains, [])
       |> assign(:domain_search_query, "")
       # VCS modal state
       |> assign(:linking_repo?, false)
       |> assign(:active_vcs, active_vcs)
       |> assign(:active_vcs_list, VCS.list_active_vcs())
       |> assign(:browse_provider, if(active_vcs, do: active_vcs.provider, else: "bitbucket"))
       |> assign(:selected_provider, "bitbucket")
       |> assign(:vcs_repos, [])
       |> assign(:vcs_filtered_repos, [])
       |> assign(:vcs_loading?, false)
       |> assign(:vcs_error, nil)
       |> assign(:vcs_search_query, "")
       |> assign(:modal_mode, if(active_vcs, do: "browse", else: "manual"))
       |> assign(
         :connect_form,
         to_form(
           %{
             "provider" => "bitbucket",
             "workspace" => "",
             "username" => "",
             "token" => "",
             "base_url" => ""
           },
           as: :connect
         )
       )
       |> assign(
         :manual_form,
         to_form(%{"url" => "", "kind" => "website", "notes" => ""}, as: :manual_repo)
       )
       |> assign(:viewing_repo_vulnerabilities, nil)
       |> assign(:creating_app?, false)
       |> assign(:hosting_environments, Inventory.list_hosting_environments())
       |> assign(
         :app_form,
         to_form(
           AshPhoenix.Form.for_create(Ravner.Inventory.Application, :create,
             as: "application",
             actor: if(scope, do: scope.user, else: nil)
           )
         )
       )
       |> assign(
         :mermaid_chart,
         Ravner.Architecture.MermaidSerializer.serialize_project(project)
       )}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = Map.get(params, "tab", "team")
    {:noreply, assign(socket, :current_tab, tab)}
  end

  @impl true
  def handle_event("open_link_repo", _params, socket) do
    case VcsCoordinator.handle_open_link_repo(socket) do
      {:load_repos, socket, provider} ->
        send(self(), {:load_vcs_repositories, provider})
        {:noreply, assign(socket, :vcs_loading?, true)}

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_assign_domain", _params, socket) do
    if socket.assigns.can_manage? do
      project = socket.assigns.project

      candidates =
        OwnershipStats.list_candidate_domains_for_project(
          project.id,
          project.organization_id,
          ""
        )

      {:noreply,
       socket
       |> assign(:assigning_domain?, true)
       |> assign(:domain_search_query, "")
       |> assign(:candidate_domains, candidates)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_assign_domain", _params, socket) do
    {:noreply, assign(socket, :assigning_domain?, false)}
  end

  @impl true
  def handle_event("search_candidate_domains", %{"query" => query}, socket) do
    project = socket.assigns.project

    candidates =
      OwnershipStats.list_candidate_domains_for_project(
        project.id,
        project.organization_id,
        query
      )

    {:noreply,
     socket
     |> assign(:domain_search_query, query)
     |> assign(:candidate_domains, candidates)}
  end

  @impl true
  def handle_event("assign_domain", %{"domain_id" => domain_id}, socket) do
    if socket.assigns.can_manage? do
      project = socket.assigns.project
      actor = socket.assigns.current_scope.user

      case Ravner.Domains.assign_domain_project(domain_id, project.id, actor: actor) do
        {:ok, _domain} ->
          all_domains = OwnershipStats.list_domains_for_project(project.id)
          stats = OwnershipStats.project_stats(project.id)

          candidates =
            OwnershipStats.list_candidate_domains_for_project(
              project.id,
              project.organization_id,
              socket.assigns.domain_search_query
            )

          {:noreply,
           socket
           |> assign(:all_domains, all_domains)
           |> assign(:domains, all_domains)
           |> assign(:candidate_domains, candidates)
           |> assign(:stats, stats)
           |> assign_risk_posture()
           |> put_flash(:info, "Domain assigned to project successfully.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to assign domain to project.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage this project.")}
    end
  end

  @impl true
  def handle_event("unassign_domain", %{"domain_id" => domain_id}, socket) do
    if socket.assigns.can_manage? do
      project = socket.assigns.project
      actor = socket.assigns.current_scope.user

      case Ravner.Domains.assign_domain_project(domain_id, nil, actor: actor) do
        {:ok, _domain} ->
          all_domains = OwnershipStats.list_domains_for_project(project.id)
          stats = OwnershipStats.project_stats(project.id)

          {:noreply,
           socket
           |> assign(:all_domains, all_domains)
           |> assign(:domains, all_domains)
           |> assign(:stats, stats)
           |> assign_risk_posture()
           |> put_flash(:info, "Domain removed from project.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to remove domain.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage this project.")}
    end
  end

  @impl true
  def handle_event("open_create_app", _params, socket) do
    {:noreply, assign(socket, :creating_app?, true)}
  end

  @impl true
  def handle_event("close_create_app", _params, socket) do
    {:noreply, assign(socket, :creating_app?, false)}
  end

  @impl true
  def handle_event("save_app", %{"application" => app_params}, socket) do
    scope = socket.assigns[:current_scope]
    actor = if scope, do: scope.user, else: nil
    project = socket.assigns.project

    params =
      app_params
      |> Map.put("project_id", project.id)
      |> then(fn p ->
        if Map.get(p, "slug", "") == "" do
          slug =
            p
            |> Map.get("name", "app")
            |> String.downcase()
            |> String.replace(~r/[^a-z0-9]+/, "-")
            |> String.trim("-")

          Map.put(p, "slug", slug)
        else
          p
        end
      end)

    case Inventory.create_application(params, actor: actor) do
      {:ok, _app} ->
        updated_project = Inventory.get_project!(project.id)

        {:noreply,
         socket
         |> put_flash(:info, "Application workload registered.")
         |> assign(:project, updated_project)
         |> assign(:creating_app?, false)
         |> assign(
           :mermaid_chart,
           Ravner.Architecture.MermaidSerializer.serialize_project(updated_project)
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :app_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("close_link_repo", _params, socket) do
    VcsCoordinator.handle_close_link_repo(socket)
  end

  @impl true
  def handle_event("switch_modal_mode", %{"mode" => mode}, socket) do
    case VcsCoordinator.handle_switch_modal_mode(socket, mode) do
      {:load_repos, socket, provider} ->
        send(self(), {:load_vcs_repositories, provider})
        {:noreply, assign(socket, :vcs_loading?, true)}

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_vcs", %{"query" => query}, socket) do
    VcsCoordinator.handle_search_vcs(socket, query)
  end

  @impl true
  def handle_event("link_vcs_repo", params, socket) do
    url = params["url"]
    name = params["name"]
    kind = params["kind"] || "website"
    main_language = params["main_language"]
    description = params["description"]
    default_branch = params["default_branch"] || "main"
    actor = socket.assigns.current_scope.user

    provider =
      params["provider"] || socket.assigns[:browse_provider] ||
        VCS.detect_provider_from_url(url)

    attrs = %{
      url: url,
      project_id: socket.assigns.project.id,
      kind: kind,
      provider: provider,
      external_id: name,
      main_language: main_language,
      notes: description,
      default_branch: default_branch
    }

    case Inventory.create_project_repository(attrs, actor: actor) do
      {:ok, created} ->
        # Trigger background metadata sync to fetch latest commits & tech stack
        Task.Supervisor.start_child(Ravner.TaskSupervisor, fn ->
          VCS.sync_repository_metadata(created, actor: actor)
        end)

        all_repositories = Inventory.list_project_repositories(socket.assigns.project.id)
        stats = OwnershipStats.project_stats(socket.assigns.project.id)

        {:noreply,
         socket
         |> assign(:all_repositories, all_repositories)
         |> assign(:repositories, all_repositories)
         |> assign(:stats, stats)
         |> assign_risk_posture()
         |> assign(:linking_repo?, false)
         |> put_flash(:info, "Repository '#{name}' linked successfully.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to link repositories.")}

      {:error, changeset} ->
        err = format_errors(changeset)
        {:noreply, put_flash(socket, :error, "Failed to link repository: #{err}")}
    end
  end

  @impl true
  def handle_event("save_manual_repo", %{"manual_repo" => params}, socket) do
    url = String.trim(params["url"] || "")
    kind = params["kind"] || "website"
    notes = params["notes"]
    actor = socket.assigns.current_scope.user

    if url == "" do
      {:noreply, put_flash(socket, :error, "Repository URL cannot be blank.")}
    else
      provider = VCS.detect_provider_from_url(url)
      slug = VCS.extract_slug_from_url(url)

      attrs = %{
        url: url,
        project_id: socket.assigns.project.id,
        kind: kind,
        provider: provider,
        external_id: slug,
        notes: notes
      }

      case Inventory.create_project_repository(attrs, actor: actor) do
        {:ok, created} ->
          if provider == "bitbucket" do
            Task.Supervisor.start_child(Ravner.TaskSupervisor, fn ->
              VCS.sync_repository_metadata(created, actor: actor)
            end)
          end

          all_repositories = Inventory.list_project_repositories(socket.assigns.project.id)
          stats = OwnershipStats.project_stats(socket.assigns.project.id)

          {:noreply,
           socket
           |> assign(:all_repositories, all_repositories)
           |> assign(:repositories, all_repositories)
           |> assign(:stats, stats)
           |> assign_risk_posture()
           |> assign(:linking_repo?, false)
           |> put_flash(:info, "Repository linked successfully.")}

        {:error, :forbidden} ->
          {:noreply,
           put_flash(socket, :error, "You do not have permission to link repositories.")}

        {:error, changeset} ->
          err = format_errors(changeset)
          {:noreply, put_flash(socket, :error, "Failed to link repository: #{err}")}
      end
    end
  end

  @impl true
  def handle_event("validate_connect", %{"connect" => params}, socket) do
    VcsCoordinator.handle_validate_connect(socket, params)
  end

  @impl true
  def handle_event("select_browse_provider", %{"provider" => provider}, socket) do
    case VcsCoordinator.handle_select_browse_provider(socket, provider) do
      {:load_repos, socket, provider} ->
        send(self(), {:load_vcs_repositories, provider})
        {:noreply, assign(socket, :vcs_loading?, true)}

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_vcs_connection", %{"connect" => params}, socket) do
    case VcsCoordinator.handle_save_vcs_connection(socket, params, &put_flash/3) do
      {:load_repos, socket, provider} ->
        send(self(), {:load_vcs_repositories, provider})
        {:noreply, assign(socket, :vcs_loading?, true)}

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_bitbucket_connection", params, socket) do
    handle_event("save_vcs_connection", params, socket)
  end

  @impl true
  def handle_event("sync_repo", %{"id" => id}, socket) do
    VcsCoordinator.handle_sync_repo(socket, id, &put_flash/3, fn socket, _synced ->
      all_repositories = Inventory.list_project_repositories(socket.assigns.project.id)

      socket
      |> assign(:all_repositories, all_repositories)
      |> assign(:repositories, all_repositories)
    end)
  end

  @impl true
  def handle_event("scan_repo", %{"id" => id}, socket) do
    VcsCoordinator.handle_scan_repo(socket, id, &put_flash/3, fn socket, updated_repo, vulns ->
      all_repositories = Inventory.list_project_repositories(socket.assigns.project.id)

      viewing =
        if socket.assigns.viewing_repo_vulnerabilities &&
             socket.assigns.viewing_repo_vulnerabilities.repository.id == updated_repo.id do
          %{repository: updated_repo, vulnerabilities: vulns}
        else
          socket.assigns.viewing_repo_vulnerabilities
        end

      socket
      |> assign(:all_repositories, all_repositories)
      |> assign(:repositories, all_repositories)
      |> assign(:viewing_repo_vulnerabilities, viewing)
      |> assign_risk_posture()
    end)
  end

  @impl true
  def handle_event("view_repo_vulnerabilities", %{"id" => id}, socket) do
    repo = Inventory.get_project_repository!(id)
    vulns = Ravner.SecurityScans.list_repository_vulnerabilities(repo.id)

    {:noreply,
     assign(socket, :viewing_repo_vulnerabilities, %{repository: repo, vulnerabilities: vulns})}
  end

  @impl true
  def handle_event("close_repo_vulnerabilities", _params, socket) do
    {:noreply, assign(socket, :viewing_repo_vulnerabilities, nil)}
  end

  @impl true
  def handle_event("unlink_repo", %{"id" => id}, socket) do
    repo = Inventory.get_project_repository!(id)
    actor = socket.assigns.current_scope.user

    case Inventory.delete_project_repository(repo, actor: actor) do
      {:ok, _} ->
        all_repositories = Inventory.list_project_repositories(socket.assigns.project.id)
        stats = OwnershipStats.project_stats(socket.assigns.project.id)

        {:noreply,
         socket
         |> assign(:all_repositories, all_repositories)
         |> assign(:repositories, all_repositories)
         |> assign(:stats, stats)
         |> assign_risk_posture()
         |> put_flash(:info, "Repository unlinked from project.")}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to unlink repositories.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unlink repository.")}
    end
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

  @impl true
  def handle_info(:load_vcs_repositories, socket) do
    provider = socket.assigns[:browse_provider] || "bitbucket"
    handle_info({:load_vcs_repositories, provider}, socket)
  end

  @impl true
  def handle_info({:load_vcs_repositories, provider}, socket) do
    VcsCoordinator.load_vcs_repositories(socket, provider)
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
        (r.kind && String.contains?(String.downcase(r.kind), term)) ||
        (r.technology && String.contains?(String.downcase(r.technology), term)) ||
        (r.main_language && String.contains?(String.downcase(r.main_language), term)) ||
        (r.domain && String.contains?(String.downcase(r.domain.name), term))
    end)
  end

  defp filter_project_domains(domains, ""), do: domains

  defp filter_project_domains(domains, term) do
    Enum.filter(domains, fn d ->
      String.contains?(String.downcase(d.name), term)
    end)
  end

  defp assign_risk_posture(socket) do
    risk_posture = Ravner.Governance.RiskScore.calculate_for_project(socket.assigns.project.id)
    assign(socket, :risk_posture, risk_posture)
  end

  defp format_errors(err), do: VcsCoordinator.format_errors(err)
end
