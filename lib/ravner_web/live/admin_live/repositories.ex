defmodule RavnerWeb.AdminLive.Repositories do
  @moduledoc """
  Central administration dashboard for managing all connected source code repositories,
  their governance associations (projects, organizations, domains), technical stacks,
  commit tracking, and dependency vulnerabilities.
  """
  use RavnerWeb, :live_view

  alias Ravner.Integrations.VCS
  alias Ravner.Inventory
  alias RavnerWeb.VcsCoordinator

  @impl true
  def mount(_params, _session, socket) do
    if can_access?(socket.assigns.current_scope) do
      all_repositories = Inventory.list_all_repositories()
      stats = Inventory.repository_stats()
      projects = Inventory.list_projects()
      active_list = VCS.list_active_vcs()
      first_provider = if active_list != [], do: hd(active_list).provider, else: "bitbucket"

      {:ok,
       socket
       |> assign(:page_title, "Code Repositories")
       |> assign(:active_tab, :repositories)
       |> assign(:all_repositories, all_repositories)
       |> assign(:repositories, all_repositories)
       |> assign(:stats, stats)
       |> assign(:projects, projects)
       |> assign(:active_vcs_list, active_list)
       |> assign(:active_vcs, List.first(active_list))
       |> assign(:providers_status, build_providers_status())
       |> assign(:browse_provider, first_provider)
       |> assign(:selected_provider, "bitbucket")
       |> assign(:search_query, "")
       |> assign(:filter_provider, "all")
       |> assign(:filter_status, "all")
       |> assign(:filter_kind, "all")
       # Modal state
       |> assign(:linking_repo?, false)
       |> assign(:modal_mode, if(active_list != [], do: "browse", else: "manual"))
       |> assign(:vcs_repos, [])
       |> assign(:vcs_filtered_repos, [])
       |> assign(:vcs_loading?, false)
       |> assign(:vcs_error, nil)
       |> assign(:vcs_search_query, "")
       |> assign(:viewing_vulns, nil)
       |> assign(:viewing_secrets, nil)
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
         to_form(
           %{
             "url" => "",
             "project_id" => "",
             "kind" => "website",
             "notes" => ""
           },
           as: :manual_repo
         )
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Editor or administrator access required")
       |> push_navigate(to: ~p"/domains")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # ── Filter & Search Events ──────────────────────────────────────────────────

  @impl true
  def handle_event("search", params, socket) do
    query = Map.get(params, "query") || Map.get(params, "value", "")
    socket = assign(socket, :search_query, query)
    {:noreply, apply_filters(socket)}
  end

  @impl true
  def handle_event("filter_provider", %{"provider" => provider}, socket) do
    socket = assign(socket, :filter_provider, provider)
    {:noreply, apply_filters(socket)}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    socket = assign(socket, :filter_status, status)
    {:noreply, apply_filters(socket)}
  end

  @impl true
  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    socket = assign(socket, :filter_kind, kind)
    {:noreply, apply_filters(socket)}
  end

  # ── Repository Actions ──────────────────────────────────────────────────────

  @impl true
  def handle_event("scan_repo", %{"id" => id}, socket) do
    VcsCoordinator.handle_scan_repo(socket, id, &put_flash/3, fn socket, updated_repo, vulns ->
      all_repositories = Inventory.list_all_repositories()
      stats = Inventory.repository_stats()

      viewing =
        if socket.assigns.viewing_vulns &&
             socket.assigns.viewing_vulns.repository.id == updated_repo.id do
          %{repository: updated_repo, vulnerabilities: vulns}
        else
          socket.assigns.viewing_vulns
        end

      socket
      |> assign(:all_repositories, all_repositories)
      |> assign(:stats, stats)
      |> assign(:viewing_vulns, viewing)
      |> apply_filters()
    end)
  end

  @impl true
  def handle_event("sync_repo", %{"id" => id}, socket) do
    VcsCoordinator.handle_sync_repo(socket, id, &put_flash/3, fn socket, _synced ->
      all_repositories = Inventory.list_all_repositories()

      socket
      |> assign(:all_repositories, all_repositories)
      |> apply_filters()
    end)
  end

  @impl true
  def handle_event("delete_repo", %{"id" => id}, socket) do
    repo = Inventory.get_project_repository!(id)
    actor = socket.assigns.current_scope.user

    case Inventory.delete_project_repository(repo, actor: actor) do
      {:ok, _} ->
        all_repositories = Inventory.list_all_repositories()
        stats = Inventory.repository_stats()

        {:noreply,
         socket
         |> assign(:all_repositories, all_repositories)
         |> assign(:stats, stats)
         |> apply_filters()
         |> put_flash(:info, "Repository removed from inventory.")}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to delete repositories.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete repository.")}
    end
  end

  @impl true
  def handle_event("view_vulns", %{"id" => id}, socket) do
    repo = Inventory.get_project_repository!(id)
    vulns = Inventory.list_repository_vulnerabilities(repo.id)

    {:noreply, assign(socket, :viewing_vulns, %{repository: repo, vulnerabilities: vulns})}
  end

  @impl true
  def handle_event("close_vulns", _params, socket) do
    {:noreply, assign(socket, :viewing_vulns, nil)}
  end

  @impl true
  def handle_event("view_secrets", %{"id" => id}, socket) do
    repo = Inventory.get_project_repository!(id)
    secrets = Inventory.list_repository_secrets(repo.id)

    {:noreply, assign(socket, :viewing_secrets, %{repository: repo, secrets: secrets})}
  end

  @impl true
  def handle_event("close_secrets", _params, socket) do
    {:noreply, assign(socket, :viewing_secrets, nil)}
  end

  @impl true
  def handle_event("mark_secret_status", %{"id" => secret_id, "status" => status}, socket) do
    case Inventory.mark_secret_status(secret_id, status) do
      {:ok, _} ->
        socket =
          if socket.assigns[:viewing_secrets] do
            repo_id = socket.assigns.viewing_secrets.repository.id
            repo = Inventory.get_project_repository!(repo_id)
            secrets = Inventory.list_repository_secrets(repo_id)
            assign(socket, :viewing_secrets, %{repository: repo, secrets: secrets})
          else
            socket
          end

        all_repositories = Inventory.list_all_repositories()
        stats = Inventory.repository_stats()

        {:noreply,
         socket
         |> assign(:all_repositories, all_repositories)
         |> assign(:stats, stats)
         |> apply_filters()
         |> put_flash(:info, "Secret marked as #{status}")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to update secret status: #{inspect(reason)}")}
    end
  end

  # ── Modal Events ────────────────────────────────────────────────────────────

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
  def handle_event("open_connect_provider", %{"provider" => provider}, socket) do
    existing = VCS.safe_active_vcs(provider)

    connect_form =
      to_form(
        %{
          "provider" => provider,
          "workspace" => (existing && existing.workspace) || "",
          "token_type" => (existing && existing.token_type) || "workspace",
          "repo_slug" => (existing && existing.repo_slug) || "",
          "token" => "",
          "base_url" => (existing && existing.settings["base_url"]) || ""
        },
        as: :connect
      )

    {:noreply,
     socket
     |> assign(:linking_repo?, true)
     |> assign(:modal_mode, "connect")
     |> assign(:selected_provider, provider)
     |> assign(:connect_form, connect_form)}
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
  def handle_event("search_vcs", %{"query" => query}, socket) do
    VcsCoordinator.handle_search_vcs(socket, query)
  end

  @impl true
  def handle_event("validate_connect", %{"connect" => params}, socket) do
    VcsCoordinator.handle_validate_connect(socket, params)
  end

  @impl true
  def handle_event("save_vcs_connection", %{"connect" => params}, socket) do
    case VcsCoordinator.handle_save_vcs_connection(socket, params, &put_flash/3) do
      {:load_repos, socket, provider} ->
        send(self(), {:load_vcs_repositories, provider})

        {:noreply,
         socket
         |> assign(:providers_status, build_providers_status())
         |> assign(:vcs_loading?, true)}

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("link_vcs_repo", params, socket) do
    url = params["url"]
    name = params["name"]
    kind = params["kind"] || "website"
    project_id = parse_id(params["project_id"])
    main_language = params["main_language"]
    description = params["description"]
    default_branch = params["default_branch"] || "main"

    provider =
      params["provider"] || socket.assigns[:browse_provider] || VCS.detect_provider_from_url(url)

    actor = socket.assigns.current_scope.user

    attrs = %{
      url: url,
      project_id: project_id,
      kind: kind,
      provider: provider,
      external_id: name,
      main_language: main_language,
      notes: description,
      default_branch: default_branch
    }

    case Inventory.create_project_repository(attrs, actor: actor) do
      {:ok, created} ->
        Task.Supervisor.start_child(Ravner.TaskSupervisor, fn ->
          VCS.sync_repository_metadata(created, actor: actor)
        end)

        all_repositories = Inventory.list_all_repositories()
        stats = Inventory.repository_stats()

        {:noreply,
         socket
         |> assign(:all_repositories, all_repositories)
         |> assign(:stats, stats)
         |> assign(:linking_repo?, false)
         |> apply_filters()
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
    project_id = parse_id(params["project_id"])
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
        project_id: project_id,
        kind: kind,
        provider: provider,
        external_id: slug,
        notes: notes
      }

      case Inventory.create_project_repository(attrs, actor: actor) do
        {:ok, created} ->
          if provider in ["bitbucket", "github", "gitlab"] do
            Task.Supervisor.start_child(Ravner.TaskSupervisor, fn ->
              VCS.sync_repository_metadata(created, actor: actor)
            end)
          end

          all_repositories = Inventory.list_all_repositories()
          stats = Inventory.repository_stats()

          {:noreply,
           socket
           |> assign(:all_repositories, all_repositories)
           |> assign(:stats, stats)
           |> assign(:linking_repo?, false)
           |> apply_filters()
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

  # ── Info Handlers ───────────────────────────────────────────────────────────

  @impl true
  def handle_info(:load_vcs_repositories, socket) do
    provider = socket.assigns[:browse_provider] || "bitbucket"
    handle_info({:load_vcs_repositories, provider}, socket)
  end

  @impl true
  def handle_info({:load_vcs_repositories, provider}, socket) do
    VcsCoordinator.load_vcs_repositories(socket, provider)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp apply_filters(socket) do
    query = String.downcase(socket.assigns.search_query)
    provider = socket.assigns.filter_provider
    status = socket.assigns.filter_status
    kind = socket.assigns.filter_kind

    filtered =
      socket.assigns.all_repositories
      |> Enum.filter(fn r ->
        match_query?(r, query) and
          match_provider?(r, provider) and
          match_status?(r, status) and
          match_kind?(r, kind)
      end)

    assign(socket, :repositories, filtered)
  end

  defp match_query?(_r, ""), do: true

  defp match_query?(r, q) do
    url = String.downcase(r.url || "")
    name = String.downcase(r.external_id || "")
    notes = String.downcase(r.notes || "")
    tech = String.downcase(r.technology || "")
    lang = String.downcase(r.main_language || "")
    project_name = if r.project, do: String.downcase(r.project.name || ""), else: ""
    domain_name = if r.domain, do: String.downcase(r.domain.name || ""), else: ""

    String.contains?(url, q) or
      String.contains?(name, q) or
      String.contains?(notes, q) or
      String.contains?(tech, q) or
      String.contains?(lang, q) or
      String.contains?(project_name, q) or
      String.contains?(domain_name, q)
  end

  defp match_provider?(_r, "all"), do: true
  defp match_provider?(r, provider), do: to_string(r.provider) == provider

  defp match_status?(_r, "all"), do: true
  defp match_status?(r, "vulnerable"), do: (r.vulnerability_count || 0) > 0

  defp match_status?(r, "clean"),
    do: r.scan_status == "scanned" and (r.vulnerability_count || 0) == 0

  defp match_status?(r, "unscanned"), do: r.scan_status == "unscanned" or is_nil(r.scan_status)

  defp match_kind?(_r, "all"), do: true
  defp match_kind?(r, kind), do: to_string(r.kind) == kind

  defp build_providers_status do
    [
      %{
        provider: "bitbucket",
        name: "Bitbucket Cloud",
        active: VCS.safe_active_vcs("bitbucket"),
        icon: "hero-circle-stack"
      },
      %{
        provider: "github",
        name: "GitHub",
        active: VCS.safe_active_vcs("github"),
        icon: "hero-code-bracket"
      },
      %{
        provider: "gitlab",
        name: "GitLab",
        active: VCS.safe_active_vcs("gitlab"),
        icon: "hero-cube"
      }
    ]
  end

  defp can_access?(nil), do: false
  defp can_access?(scope), do: scope.user && scope.user.role in [:admin, :editor]

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil
  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp format_errors(err), do: VcsCoordinator.format_errors(err)
end
