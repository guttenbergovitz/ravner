defmodule RavnerWeb.DomainLive.VcsPanel do
  @moduledoc """
  LiveComponent managing domain connected source code repositories and VCS integration.
  Encapsulates repository cards, commit pulse, scanning/syncing actions, and the full
  repository linking modal (Project Repositories, Browse VCS, Manual URL, and Connect Provider).
  """
  use RavnerWeb, :live_component

  alias Ravner.Domains
  alias Ravner.Integrations.VCS
  alias Ravner.Inventory
  alias RavnerWeb.VcsCoordinator
  import RavnerWeb.DomainComponents, only: [format_relative_timestamp: 1]

  defp notify_flash(socket, kind, msg), do: VcsCoordinator.notify_flash(socket, kind, msg)

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:linking_repo?, false)
     |> assign(:modal_mode, "browse")
     |> assign(:active_vcs, nil)
     |> assign(:active_vcs_list, [])
     |> assign(:browse_provider, "bitbucket")
     |> assign(:selected_provider, "bitbucket")
     |> assign(:vcs_repos, [])
     |> assign(:vcs_filtered_repos, [])
     |> assign(:vcs_loading?, false)
     |> assign(:vcs_search_query, "")
     |> assign(:vcs_error, nil)
     |> assign(:manual_form, to_form(%{}, as: :manual_repo))
     |> assign(
       :connect_form,
       to_form(%{"provider" => "bitbucket", "token_type" => "workspace"}, as: :connect)
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  # ─── Modal open/close & tab navigation ─────────────────────────────────────

  @impl true
  def handle_event("open_link_repo", _params, socket) do
    if can_manage?(socket) do
      project_repos = socket.assigns[:project_repos] || []

      case VcsCoordinator.handle_open_link_repo(socket, project_repos: project_repos) do
        {:load_repos, socket, provider} -> load_vcs_repos(socket, provider)
        {:noreply, socket} -> {:noreply, socket}
      end
    else
      {:noreply, notify_flash(socket, :error, "You do not have permission to link repositories.")}
    end
  end

  @impl true
  def handle_event("close_link_repo", _params, socket) do
    VcsCoordinator.handle_close_link_repo(socket)
  end

  @impl true
  def handle_event("switch_modal_mode", %{"mode" => mode}, socket) do
    case VcsCoordinator.handle_switch_modal_mode(socket, mode) do
      {:load_repos, socket, provider} -> load_vcs_repos(socket, provider)
      {:noreply, socket} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_browse_provider", %{"provider" => provider}, socket) do
    case VcsCoordinator.handle_select_browse_provider(socket, provider) do
      {:load_repos, socket, provider} -> load_vcs_repos(socket, provider)
      {:noreply, socket} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_vcs", %{"query" => query}, socket) do
    VcsCoordinator.handle_search_vcs(socket, query)
  end

  # ─── Repository actions: linking, syncing, scanning, unlinking ─────────────

  @impl true
  def handle_event("link_project_repo", %{"repo_id" => repo_id}, socket) do
    if can_manage?(socket) do
      source_repo = Inventory.get_project_repository!(repo_id)
      domain = socket.assigns.domain
      actor = socket.assigns.current_scope.user
      is_primary = is_nil(socket.assigns.primary_repo)

      case Inventory.update_project_repository(
             source_repo,
             %{domain_id: domain.id, is_primary: is_primary},
             actor: actor
           ) do
        {:ok, updated} ->
          Task.Supervisor.start_child(Ravner.TaskSupervisor, fn ->
            VCS.sync_repository_metadata(updated, actor: actor)
          end)

          if is_primary do
            Domains.update_domain(domain, %{repository_url: updated.url}, actor: actor)
          end

          Domains.sync_all_vcs_tech_evidence_for_domain(domain.id)
          send(self(), {:vcs_repo_changed, domain.id})

          {:noreply,
           socket
           |> assign(:linking_repo?, false)
           |> put_flash(
             :info,
             "Repository '#{updated.external_id || updated.url}' linked to domain."
           )}

        {:error, _} ->
          {:noreply, notify_flash(socket, :error, "Failed to link project repository.")}
      end
    else
      {:noreply, notify_flash(socket, :error, "You do not have permission to link repositories.")}
    end
  end

  @impl true
  def handle_event("link_vcs_repo", params, socket) do
    if can_manage?(socket) do
      domain = socket.assigns.domain
      actor = socket.assigns.current_scope.user
      url = params["url"]
      name = params["name"]
      kind = params["kind"] || "website"
      main_language = params["main_language"]
      description = params["description"]
      default_branch = params["default_branch"] || "main"
      is_primary = is_nil(socket.assigns.primary_repo)

      provider =
        params["provider"] || socket.assigns[:browse_provider] ||
          VCS.detect_provider_from_url(url)

      attrs = %{
        url: url,
        domain_id: domain.id,
        project_id: domain.project_id,
        kind: kind,
        provider: provider,
        external_id: name,
        main_language: main_language,
        notes: description,
        default_branch: default_branch,
        is_primary: is_primary
      }

      case Inventory.create_project_repository(attrs, actor: actor) do
        {:ok, created} ->
          Task.Supervisor.start_child(Ravner.TaskSupervisor, fn ->
            VCS.sync_repository_metadata(created, actor: actor)
          end)

          if is_primary do
            Domains.update_domain(domain, %{repository_url: url}, actor: actor)
          end

          Domains.sync_all_vcs_tech_evidence_for_domain(domain.id)
          send(self(), {:vcs_repo_changed, domain.id})

          {:noreply,
           socket
           |> assign(:linking_repo?, false)
           |> put_flash(:info, "Repository '#{name}' linked to domain.")}

        {:error, :forbidden} ->
          {:noreply,
           notify_flash(socket, :error, "You do not have permission to link repositories.")}

        {:error, changeset} ->
          err = format_errors(changeset)
          {:noreply, notify_flash(socket, :error, "Failed to link repository: #{err}")}
      end
    else
      {:noreply, notify_flash(socket, :error, "You do not have permission to link repositories.")}
    end
  end

  @impl true
  def handle_event("save_manual_repo", %{"manual_repo" => params}, socket) do
    if can_manage?(socket) do
      url = String.trim(params["url"] || "")
      kind = params["kind"] || "website"
      notes = params["notes"]
      domain = socket.assigns.domain
      actor = socket.assigns.current_scope.user
      is_primary = is_nil(socket.assigns.primary_repo)

      if url == "" do
        {:noreply, notify_flash(socket, :error, "Repository URL cannot be blank.")}
      else
        provider = VCS.detect_provider_from_url(url)
        slug = VCS.extract_slug_from_url(url)

        attrs = %{
          url: url,
          domain_id: domain.id,
          project_id: domain.project_id,
          kind: kind,
          provider: provider,
          external_id: slug,
          notes: notes,
          is_primary: is_primary
        }

        case Inventory.create_project_repository(attrs, actor: actor) do
          {:ok, created} ->
            if provider == "bitbucket" do
              Task.Supervisor.start_child(Ravner.TaskSupervisor, fn ->
                VCS.sync_repository_metadata(created, actor: actor)
              end)
            end

            if is_primary do
              Domains.update_domain(domain, %{repository_url: url}, actor: actor)
            end

            Domains.sync_all_vcs_tech_evidence_for_domain(domain.id)
            send(self(), {:vcs_repo_changed, domain.id})

            {:noreply,
             socket
             |> assign(:linking_repo?, false)
             |> put_flash(:info, "Repository linked to domain successfully.")}

          {:error, :forbidden} ->
            {:noreply,
             notify_flash(socket, :error, "You do not have permission to link repositories.")}

          {:error, changeset} ->
            err = format_errors(changeset)
            {:noreply, notify_flash(socket, :error, "Failed to link repository: #{err}")}
        end
      end
    else
      {:noreply, notify_flash(socket, :error, "You do not have permission to link repositories.")}
    end
  end

  @impl true
  def handle_event("validate_connect", %{"connect" => params}, socket) do
    VcsCoordinator.handle_validate_connect(socket, params)
  end

  @impl true
  def handle_event("save_vcs_connection", %{"connect" => params}, socket) do
    if can_manage?(socket) do
      case VcsCoordinator.handle_save_vcs_connection(socket, params, &notify_flash/3) do
        {:load_repos, socket, provider} -> load_vcs_repos(socket, provider)
        {:noreply, socket} -> {:noreply, socket}
      end
    else
      {:noreply, notify_flash(socket, :error, "You do not have permission.")}
    end
  end

  @impl true
  def handle_event("save_bitbucket_connection", params, socket) do
    handle_event("save_vcs_connection", params, socket)
  end

  @impl true
  def handle_event("sync_repo", %{"id" => id}, socket) do
    if can_manage?(socket) do
      VcsCoordinator.handle_sync_repo(socket, id, &notify_flash/3, fn socket, _synced ->
        Domains.sync_all_vcs_tech_evidence_for_domain(socket.assigns.domain.id)
        send(self(), {:vcs_repo_changed, socket.assigns.domain.id})
        socket
      end)
    else
      {:noreply, notify_flash(socket, :error, "You do not have permission.")}
    end
  end

  @impl true
  def handle_event("scan_repo", %{"id" => id}, socket) do
    if can_scan?(socket) do
      VcsCoordinator.handle_scan_repo(socket, id, &notify_flash/3, fn socket, _repo, _vulns ->
        send(self(), {:vcs_repo_changed, socket.assigns.domain.id})
        socket
      end)
    else
      {:noreply, notify_flash(socket, :error, "You do not have permission to scan repositories.")}
    end
  end

  @impl true
  def handle_event("set_primary_repo", %{"id" => id}, socket) do
    if can_manage?(socket) do
      domain = socket.assigns.domain
      actor = socket.assigns.current_scope.user

      case Inventory.set_primary_repository_for_domain(id, domain.id, actor) do
        {:ok, updated} ->
          Domains.sync_all_vcs_tech_evidence_for_domain(domain.id)
          Domains.update_domain(domain, %{repository_url: updated.url}, actor: actor)
          send(self(), {:vcs_repo_changed, domain.id})

          {:noreply,
           put_flash(
             socket,
             :info,
             "Repository '#{updated.external_id || updated.url}' set as primary."
           )}

        {:error, _} ->
          {:noreply, notify_flash(socket, :error, "Failed to set primary repository.")}
      end
    else
      {:noreply, notify_flash(socket, :error, "You do not have permission.")}
    end
  end

  @impl true
  def handle_event("unlink_repo", %{"id" => id}, socket) do
    if can_manage?(socket) do
      repo = Inventory.get_project_repository!(id)
      actor = socket.assigns.current_scope.user
      domain = socket.assigns.domain

      res =
        if repo.domain_id == domain.id and is_nil(repo.project_id) do
          Inventory.delete_project_repository(repo, actor: actor)
        else
          Inventory.update_project_repository(repo, %{domain_id: nil, is_primary: false},
            actor: actor
          )
        end

      case res do
        {:ok, _} ->
          remaining = Inventory.list_domain_repositories(domain.id)

          if repo.is_primary and remaining != [] do
            [new_primary | _] = remaining
            Inventory.set_primary_repository_for_domain(new_primary.id, domain.id, actor)
          else
            if domain.repository_url == repo.url do
              Domains.update_domain(domain, %{repository_url: nil}, actor: actor)
            end
          end

          Domains.sync_all_vcs_tech_evidence_for_domain(domain.id)
          send(self(), {:vcs_repo_changed, domain.id})

          {:noreply, notify_flash(socket, :info, "Repository unlinked from domain.")}

        {:error, _} ->
          {:noreply, notify_flash(socket, :error, "Failed to unlink repository.")}
      end
    else
      {:noreply, notify_flash(socket, :error, "You do not have permission.")}
    end
  end

  # ─── Helpers ───────────────────────────────────────────────────────────────

  defp load_vcs_repos(socket, provider) do
    case VCS.list_repositories(provider) do
      {:ok, repos} ->
        {:noreply,
         socket
         |> assign(:vcs_repos, repos)
         |> assign(:vcs_filtered_repos, repos)
         |> assign(:vcs_loading?, false)
         |> assign(:vcs_error, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:vcs_loading?, false)
         |> assign(:vcs_error, reason)}
    end
  end

  defp can_manage?(socket) do
    case socket.assigns[:can_manage?] do
      nil ->
        scope = socket.assigns[:current_scope]
        scope && (scope.admin? || scope.editor?)

      val ->
        val
    end
  end

  defp can_scan?(socket) do
    case socket.assigns[:can_scan?] do
      nil -> can_manage?(socket)
      val -> val
    end
  end

  defp format_errors(err), do: VcsCoordinator.format_errors(err)

  # ─── Render template ───────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id="vcs-panel-component">
      <%!-- Source Code & Repositories Card --%>
      <div class="card-line" id="domain-repository-card">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-normal tracking-wide uppercase flex items-center gap-2">
            <.icon name="hero-code-bracket" class="w-4 h-4 text-neutral-500" />
            Source Code & Repositories
            <%= if @domain_repos != [] do %>
              <span class="text-xs font-light text-neutral-400">
                ({length(@domain_repos)})
              </span>
            <% end %>
          </h2>
          <%= if @can_manage? and @domain_repos != [] do %>
            <button
              type="button"
              phx-click="open_link_repo"
              phx-target={@myself}
              id="link-domain-repo-btn"
              class="btn-line text-[11px] py-1 px-2.5 inline-flex items-center gap-1.5"
            >
              <.icon name="hero-plus" class="w-3.5 h-3.5" /> Link Repository
            </button>
          <% end %>
        </div>

        <%= if @domain_repos != [] do %>
          <div class="divide-y divide-neutral-100 dark:divide-neutral-800 border border-neutral-200 dark:border-neutral-700 rounded-md">
            <%= for repo <- @domain_repos do %>
              <% is_primary = repo.id == (@primary_repo && @primary_repo.id) %>
              <div
                class="p-4 flex items-start justify-between gap-4 hover:bg-neutral-50/50 dark:hover:bg-neutral-800/40 transition-colors"
                id={"domain-repo-row-#{repo.id}"}
              >
                <div class="flex items-start gap-3 min-w-0 flex-1">
                  <div class="w-9 h-9 rounded bg-neutral-100 flex items-center justify-center shrink-0 dark:bg-neutral-700">
                    <%= case repo.provider do %>
                      <% "bitbucket" -> %>
                        <.icon
                          name="hero-code-bracket-square"
                          class="w-5 h-5 text-blue-600 dark:text-blue-400"
                        />
                      <% "github" -> %>
                        <.icon
                          name="hero-code-bracket-square"
                          class="w-5 h-5 text-neutral-900 dark:text-neutral-100"
                        />
                      <% "gitlab" -> %>
                        <.icon
                          name="hero-code-bracket-square"
                          class="w-5 h-5 text-orange-600 dark:text-orange-400"
                        />
                      <% _ -> %>
                        <.icon name="hero-code-bracket" class="w-5 h-5 text-neutral-400" />
                    <% end %>
                  </div>
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2 flex-wrap">
                      <a
                        href={repo.url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="text-sm font-medium text-neutral-900 hover:text-blue-600 dark:text-neutral-100 dark:hover:text-blue-400 transition-colors inline-flex items-center gap-1"
                      >
                        {repo.external_id || repo.url}
                        <.icon
                          name="hero-arrow-top-right-on-square"
                          class="w-3.5 h-3.5 opacity-60"
                        />
                      </a>

                      <span class={[
                        "text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded border font-mono",
                        case repo.provider do
                          "bitbucket" ->
                            "bg-blue-50 text-blue-700 border-blue-200 dark:bg-blue-950 dark:text-blue-300 dark:border-blue-800"

                          "github" ->
                            "bg-neutral-100 text-neutral-800 border-neutral-300 dark:bg-neutral-800 dark:text-neutral-200 dark:border-neutral-700"

                          "gitlab" ->
                            "bg-orange-50 text-orange-700 border-orange-200 dark:bg-orange-950 dark:text-orange-300 dark:border-orange-800"

                          _ ->
                            "bg-neutral-50 text-neutral-600 border-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:border-neutral-700"
                        end
                      ]}>
                        {repo.provider || "git"}
                      </span>

                      <span class="text-[9px] uppercase tracking-widest text-neutral-500 border border-neutral-200 px-1.5 py-0.5 dark:text-neutral-400 dark:border-neutral-700">
                        {repo.kind}
                      </span>

                      <%= if is_primary do %>
                        <span
                          class="text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded border font-semibold bg-emerald-50 text-emerald-700 border-emerald-200 dark:bg-emerald-950 dark:text-emerald-300 dark:border-emerald-800"
                          title="Primary code repository for this domain"
                        >
                          Primary
                        </span>
                      <% else %>
                        <%= if repo.domain_id == @domain.id do %>
                          <span
                            class="text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded border bg-neutral-100 text-neutral-600 border-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:border-neutral-700"
                            title="Domain component repository"
                          >
                            Component
                          </span>
                        <% else %>
                          <span
                            class="text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded border bg-amber-50 text-amber-700 border-amber-200 dark:bg-amber-950 dark:text-amber-300 dark:border-amber-800"
                            title="Shared from assigned project"
                          >
                            Project Repo
                          </span>
                        <% end %>
                      <% end %>

                      <%= if repo.default_branch do %>
                        <span class="text-[9px] text-neutral-400 font-mono flex items-center gap-1">
                          <.icon name="hero-arrow-path" class="w-3 h-3" />
                          {repo.default_branch}
                        </span>
                      <% end %>

                      <%!-- Security / SCA status badge --%>
                      <%= case repo.scan_status do %>
                        <% "clean" -> %>
                          <span
                            class="text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded border font-mono bg-emerald-50 text-emerald-700 border-emerald-200 dark:bg-emerald-950 dark:text-emerald-300 dark:border-emerald-800 inline-flex items-center gap-1"
                            title="0 known dependencies vulnerabilities discovered"
                          >
                            <.icon
                              name="hero-shield-check"
                              class="w-3 h-3 text-emerald-600"
                            /> Clean
                          </span>
                        <% "vulnerable" -> %>
                          <.link
                            navigate={~p"/domains/#{@domain.id}/security?tab=cves"}
                            class="text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded border font-mono bg-red-50 text-red-700 border-red-200 dark:bg-red-950 dark:text-red-300 dark:border-red-800 hover:bg-red-100 dark:hover:bg-red-900 inline-flex items-center gap-1 transition-colors"
                            title={"#{repo.vulnerability_count} vulnerabilities detected. Click to view in security report."}
                          >
                            <.icon
                              name="hero-shield-exclamation"
                              class="w-3 h-3 text-red-600"
                            />
                            <span>{repo.vulnerability_count} CVEs</span>
                            <%= if repo.critical_vuln_count > 0 do %>
                              <span class="font-bold text-[8px]">
                                ({repo.critical_vuln_count} crit)
                              </span>
                            <% end %>
                          </.link>
                        <% "scanning" -> %>
                          <span class="text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded border font-mono bg-amber-50 text-amber-700 border-amber-200 dark:bg-amber-950 dark:text-amber-300 dark:border-amber-800 inline-flex items-center gap-1 animate-pulse">
                            <.icon
                              name="hero-arrow-path"
                              class="w-3 h-3 animate-spin text-amber-600"
                            /> Scanning...
                          </span>
                        <% _ -> %>
                          <span
                            class="text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded border font-mono bg-neutral-100 text-neutral-500 border-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:border-neutral-700 inline-flex items-center gap-1 opacity-70"
                            title="Dependencies not yet scanned for CVEs"
                          >
                            <.icon
                              name="hero-shield-exclamation"
                              class="w-3 h-3 text-neutral-400"
                            /> Unscanned
                          </span>
                      <% end %>
                    </div>

                    <%!-- Live commit pulse --%>
                    <%= if repo.last_commit_hash do %>
                      <div class="mt-2 flex items-center gap-2 text-xs text-neutral-600 dark:text-neutral-300 flex-wrap">
                        <span class="font-mono text-[10px] bg-neutral-100 dark:bg-neutral-700 px-1.5 py-0.2 rounded border border-neutral-200 dark:border-neutral-600">
                          {String.slice(repo.last_commit_hash, 0, 7)}
                        </span>
                        <span class="font-normal text-neutral-900 dark:text-neutral-100 truncate max-w-sm sm:max-w-md">
                          {repo.last_commit_message}
                        </span>
                        <span class="text-neutral-400 text-[11px] flex items-center gap-1">
                          by {repo.last_commit_author || "committer"}
                          <%= if repo.last_commit_at do %>
                            <span>
                              • {format_relative_timestamp(repo.last_commit_at)}
                            </span>
                          <% end %>
                        </span>
                      </div>
                    <% else %>
                      <div class="mt-1.5 text-xs text-neutral-400 italic flex items-center gap-1">
                        <.icon name="hero-clock" class="w-3 h-3" />
                        <span>No commit history synced yet</span>
                      </div>
                    <% end %>

                    <%!-- Tech Stack detected from repo --%>
                    <%= if repo.technology || repo.main_language do %>
                      <div class="mt-2.5 flex items-center gap-1.5 flex-wrap">
                        <span class="text-[9px] uppercase tracking-wider text-neutral-400 font-medium mr-1">
                          Repo Stack:
                        </span>
                        <%= for tech <- String.split(repo.technology || repo.main_language || "", ",", trim: true) do %>
                          <span class="text-[10px] px-2 py-0.5 rounded border border-neutral-200 bg-neutral-50 text-neutral-700 dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-300 font-mono">
                            {String.trim(tech)}
                          </span>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>

                <div class="flex items-center gap-2 shrink-0">
                  <button
                    type="button"
                    phx-click="scan_repo"
                    phx-target={@myself}
                    phx-value-id={repo.id}
                    id={"scan-domain-repo-#{repo.id}"}
                    class="btn-line text-[11px] py-1 px-2 inline-flex items-center gap-1 text-emerald-700 border-emerald-300 hover:bg-emerald-50 dark:text-emerald-300 dark:border-emerald-700 dark:hover:bg-emerald-950"
                    title="Scan repository dependencies for CVE vulnerabilities via OSV.dev"
                  >
                    <.icon name="hero-shield-check" class="w-3.5 h-3.5" /> Scan
                  </button>

                  <button
                    type="button"
                    phx-click="sync_repo"
                    phx-target={@myself}
                    phx-value-id={repo.id}
                    class="btn-line text-[11px] py-1 px-2 inline-flex items-center gap-1"
                    title="Sync latest commits and tech stack"
                  >
                    <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> Sync
                  </button>

                  <%= if @can_manage? do %>
                    <%= if not is_primary do %>
                      <button
                        type="button"
                        phx-click="set_primary_repo"
                        phx-target={@myself}
                        phx-value-id={repo.id}
                        id={"set-primary-repo-#{repo.id}"}
                        class="text-[11px] text-neutral-500 hover:text-neutral-900 underline dark:text-neutral-400 dark:hover:text-neutral-200"
                        title="Designate as primary repository for this domain"
                      >
                        Make Primary
                      </button>
                    <% end %>

                    <button
                      type="button"
                      phx-click="unlink_repo"
                      phx-target={@myself}
                      phx-value-id={repo.id}
                      data-confirm="Are you sure you want to unlink this repository from the domain?"
                      class="p-1 text-neutral-400 hover:text-red-600 transition-colors"
                      title="Unlink repository"
                    >
                      <.icon name="hero-trash" class="w-4 h-4" />
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% else %>
          <div class="py-6 text-center border border-dashed border-neutral-200 bg-neutral-50/50 dark:border-neutral-700 dark:bg-neutral-800/50 rounded">
            <.icon name="hero-code-bracket" class="w-8 h-8 text-neutral-300 mx-auto mb-2" />
            <p class="text-xs font-light text-neutral-400 max-w-sm mx-auto mb-3">
              No code repository linked to this domain. Link a Bitbucket, GitHub, or GitLab repo to monitor commits, branch, and enrich technical stack evidence.
            </p>
            <%= if @can_manage? do %>
              <button
                type="button"
                phx-click="open_link_repo"
                phx-target={@myself}
                id="link-domain-repo-btn"
                class="btn-line text-xs py-1 px-3 inline-flex items-center gap-1"
              >
                <.icon name="hero-plus" class="w-3.5 h-3.5" /> Link Repository
              </button>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Link Repository Modal --%>
      <%= if @linking_repo? do %>
        <div
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id="link-repo-modal"
        >
          <div
            class="fixed inset-0 bg-neutral-900/60 backdrop-blur-xs transition-opacity"
            phx-click="close_link_repo"
            phx-target={@myself}
            aria-hidden="true"
          >
          </div>
          <div
            class="relative w-full max-w-2xl bg-white dark:bg-neutral-900 border border-neutral-200 dark:border-neutral-800 p-6 shadow-xl z-10 max-h-[90vh] flex flex-col"
            phx-click-stop
            id="link-repo-dialog"
          >
            <%!-- Modal Header --%>
            <div class="flex items-center justify-between mb-4 border-b border-neutral-100 pb-3 dark:border-neutral-800 shrink-0">
              <div>
                <h3 class="text-lg font-medium text-neutral-900 dark:text-neutral-100">
                  Link Repository to {@domain.name}
                </h3>
                <p class="text-xs text-neutral-500 mt-0.5">
                  Connect a code repository to monitor commit pulse and enrich technical stack evidence.
                </p>
              </div>
              <button
                type="button"
                phx-click="close_link_repo"
                phx-target={@myself}
                class="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-200 p-1"
              >
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>

            <%!-- Modal Mode Tabs --%>
            <div class="flex border-b border-neutral-200 dark:border-neutral-800 mb-4 shrink-0 flex-wrap gap-y-1">
              <%= if @project_repos != [] do %>
                <button
                  type="button"
                  phx-click="switch_modal_mode"
                  phx-target={@myself}
                  phx-value-mode="project"
                  class={[
                    "px-4 py-2 text-xs font-normal border-b-2 transition-colors flex items-center gap-1.5",
                    if(@modal_mode == "project",
                      do:
                        "border-neutral-900 text-neutral-900 dark:border-neutral-100 dark:text-neutral-100",
                      else:
                        "border-transparent text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
                    )
                  ]}
                >
                  <.icon name="hero-folder" class="w-3.5 h-3.5" />
                  Project Repositories ({length(@project_repos)})
                </button>
              <% end %>
              <%= if @active_vcs_list != [] do %>
                <button
                  type="button"
                  phx-click="switch_modal_mode"
                  phx-target={@myself}
                  phx-value-mode="browse"
                  class={[
                    "px-4 py-2 text-xs font-normal border-b-2 transition-colors flex items-center gap-1.5",
                    if(@modal_mode == "browse",
                      do:
                        "border-neutral-900 text-neutral-900 dark:border-neutral-100 dark:text-neutral-100",
                      else:
                        "border-transparent text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
                    )
                  ]}
                >
                  <.icon name="hero-code-bracket-square" class="w-3.5 h-3.5" />
                  Browse VCS ({String.capitalize(@browse_provider)})
                </button>
              <% end %>
              <button
                type="button"
                phx-click="switch_modal_mode"
                phx-target={@myself}
                phx-value-mode="manual"
                class={[
                  "px-4 py-2 text-xs font-normal border-b-2 transition-colors flex items-center gap-1.5",
                  if(@modal_mode == "manual",
                    do:
                      "border-neutral-900 text-neutral-900 dark:border-neutral-100 dark:text-neutral-100",
                    else:
                      "border-transparent text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
                  )
                ]}
              >
                <.icon name="hero-link" class="w-3.5 h-3.5" /> Manual URL
              </button>
              <button
                type="button"
                phx-click="switch_modal_mode"
                phx-target={@myself}
                phx-value-mode="connect"
                class={[
                  "px-4 py-2 text-xs font-normal border-b-2 transition-colors flex items-center gap-1.5",
                  if(@modal_mode == "connect",
                    do:
                      "border-neutral-900 text-neutral-900 dark:border-neutral-100 dark:text-neutral-100",
                    else:
                      "border-transparent text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
                  )
                ]}
              >
                <.icon name="hero-cog-6-tooth" class="w-3.5 h-3.5" /> Connect Provider
              </button>
            </div>

            <%!-- Modal Body --%>
            <div class="overflow-y-auto flex-1 pr-1">
              <%= case @modal_mode do %>
                <% "project" -> %>
                  <div class="space-y-3">
                    <p class="text-xs text-neutral-500">
                      Select a repository already configured in this domain's assigned project to link it directly:
                    </p>
                    <div class="border border-neutral-200 bg-white divide-y divide-neutral-100 dark:border-neutral-700 dark:bg-neutral-800 dark:divide-neutral-700 rounded">
                      <%= for repo <- @project_repos do %>
                        <% is_current = @primary_repo && @primary_repo.id == repo.id %>
                        <div class="p-3 hover:bg-neutral-50/50 transition-colors flex items-center justify-between gap-3 dark:hover:bg-neutral-700/50">
                          <div class="min-w-0 flex-1">
                            <div class="flex items-center gap-2">
                              <span class="text-xs font-medium text-neutral-900 dark:text-neutral-100 truncate">
                                {repo.external_id || repo.url}
                              </span>
                              <span class="text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded border font-mono bg-neutral-100 dark:bg-neutral-700 text-neutral-600 dark:text-neutral-300 border-neutral-200 dark:border-neutral-600">
                                {repo.provider || "git"}
                              </span>
                              <span class="text-[9px] uppercase tracking-widest text-neutral-500 border border-neutral-200 px-1.5 py-0.5 dark:text-neutral-400 dark:border-neutral-700">
                                {repo.kind}
                              </span>
                            </div>
                            <%= if repo.last_commit_message do %>
                              <p class="text-[11px] text-neutral-400 truncate mt-1">
                                Last commit: {repo.last_commit_message}
                              </p>
                            <% end %>
                          </div>

                          <div class="shrink-0">
                            <%= if is_current do %>
                              <span class="text-[10px] text-green-700 bg-green-50 border border-green-200 px-2 py-1 rounded dark:bg-green-950 dark:text-green-300 dark:border-green-800">
                                Currently Linked
                              </span>
                            <% else %>
                              <button
                                type="button"
                                phx-click="link_project_repo"
                                phx-target={@myself}
                                phx-value-repo_id={repo.id}
                                class="btn-line text-[11px] py-1 px-2.5 inline-flex items-center gap-1"
                              >
                                <.icon name="hero-check" class="w-3 h-3" /> Use this repo
                              </button>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% "browse" -> %>
                  <div class="space-y-4">
                    <%!-- Search filter --%>
                    <div>
                      <input
                        type="text"
                        name="query"
                        value={@vcs_search_query}
                        placeholder="Search repositories by name, language, or description..."
                        phx-change="search_vcs"
                        phx-keyup="search_vcs"
                        phx-target={@myself}
                        phx-debounce="200"
                        class="w-full px-3 py-2 border border-neutral-200 bg-white text-xs text-neutral-900 placeholder-neutral-400 focus:outline-none focus:border-neutral-900 dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100 dark:placeholder-neutral-500"
                      />
                    </div>

                    <%= if @vcs_loading? do %>
                      <div class="py-12 text-center text-xs text-neutral-400 flex flex-col items-center gap-2">
                        <.icon name="hero-arrow-path" class="w-5 h-5 animate-spin text-neutral-400" />
                        <span>Fetching repositories from Bitbucket...</span>
                      </div>
                    <% else %>
                      <%= if @vcs_error do %>
                        <div class="p-3 text-xs text-red-700 bg-red-50 border border-red-200 dark:bg-red-950/40 dark:text-red-300 dark:border-red-900 flex items-start gap-2">
                          <.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0 mt-0.5" />
                          <div class="flex-1">
                            <p class="font-medium">Error loading repositories</p>
                            <p class="mt-0.5">{@vcs_error}</p>
                            <button
                              type="button"
                              phx-click="switch_modal_mode"
                              phx-target={@myself}
                              phx-value-mode="connect"
                              class="underline mt-1 block"
                            >
                              Update workspace credentials &rarr;
                            </button>
                          </div>
                        </div>
                      <% else %>
                        <%= if @vcs_filtered_repos == [] do %>
                          <div class="py-10 text-center text-xs text-neutral-400">
                            <%= if @vcs_search_query != "" do %>
                              No repositories matching "{@vcs_search_query}".
                            <% else %>
                              No repositories found in Bitbucket workspace.
                            <% end %>
                          </div>
                        <% else %>
                          <div class="border border-neutral-200 bg-white divide-y divide-neutral-100 dark:border-neutral-700 dark:bg-neutral-800 dark:divide-neutral-700 rounded">
                            <%= for repo <- @vcs_filtered_repos do %>
                              <% is_linked =
                                @primary_repo &&
                                  (@primary_repo.url == repo.url ||
                                     @primary_repo.external_id == repo.name) %>
                              <div class="p-3 hover:bg-neutral-50/50 transition-colors flex items-center justify-between gap-3 dark:hover:bg-neutral-700/50">
                                <div class="min-w-0 flex-1">
                                  <div class="flex items-center gap-2">
                                    <span class="text-xs font-medium text-neutral-900 dark:text-neutral-100 truncate">
                                      {repo.name}
                                    </span>
                                    <%= if repo.is_private do %>
                                      <span class="text-[9px] uppercase tracking-wider px-1 py-0.2 rounded border font-mono bg-neutral-100 text-neutral-600 border-neutral-200 dark:bg-neutral-700 dark:text-neutral-300 dark:border-neutral-600">
                                        private
                                      </span>
                                    <% else %>
                                      <span class="text-[9px] uppercase tracking-wider px-1 py-0.2 rounded border font-mono bg-green-50 text-green-700 border-green-200 dark:bg-green-950 dark:text-green-300 dark:border-green-800">
                                        public
                                      </span>
                                    <% end %>
                                    <%= if repo.main_language do %>
                                      <span class="text-[9px] text-neutral-400 font-mono">
                                        {repo.main_language}
                                      </span>
                                    <% end %>
                                  </div>
                                  <%= if repo.description && repo.description != "" do %>
                                    <p class="text-[11px] text-neutral-400 truncate mt-0.5">
                                      {repo.description}
                                    </p>
                                  <% end %>
                                </div>

                                <div class="shrink-0">
                                  <%= if is_linked do %>
                                    <span class="text-[10px] text-green-700 bg-green-50 border border-green-200 px-2 py-1 rounded dark:bg-green-950 dark:text-green-300 dark:border-green-800">
                                      Linked
                                    </span>
                                  <% else %>
                                    <form
                                      phx-submit="link_vcs_repo"
                                      phx-target={@myself}
                                      class="flex items-center gap-1.5"
                                    >
                                      <input type="hidden" name="url" value={repo.url} />
                                      <input type="hidden" name="name" value={repo.name} />
                                      <input
                                        type="hidden"
                                        name="main_language"
                                        value={repo.main_language || ""}
                                      />
                                      <input
                                        type="hidden"
                                        name="description"
                                        value={repo.description || ""}
                                      />
                                      <input
                                        type="hidden"
                                        name="default_branch"
                                        value={repo.default_branch || "main"}
                                      />
                                      <select
                                        name="kind"
                                        class="text-[11px] py-1 px-1.5 border border-neutral-200 bg-white text-neutral-700 dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-300 focus:outline-none"
                                      >
                                        <option value="website">Website</option>
                                        <option value="api">API</option>
                                        <option value="worker">Worker</option>
                                        <option value="library">Library</option>
                                        <option value="mobile">Mobile</option>
                                        <option value="infrastructure">Infrastructure</option>
                                        <option value="documentation">Docs</option>
                                      </select>
                                      <button
                                        type="submit"
                                        class="btn-line text-[11px] py-1 px-2 inline-flex items-center gap-1"
                                      >
                                        <.icon name="hero-plus" class="w-3 h-3" /> Link
                                      </button>
                                    </form>
                                  <% end %>
                                </div>
                              </div>
                            <% end %>
                          </div>
                        <% end %>
                      <% end %>
                    <% end %>
                  </div>
                <% "manual" -> %>
                  <.form
                    for={@manual_form}
                    phx-submit="save_manual_repo"
                    phx-target={@myself}
                    class="space-y-4"
                  >
                    <.input
                      field={@manual_form[:url]}
                      label="Repository URL"
                      placeholder="https://bitbucket.org/workspace/repo or git@github.com:..."
                      required
                    />
                    <.input
                      field={@manual_form[:kind]}
                      type="select"
                      label="Component Kind"
                      options={[
                        {"Website", "website"},
                        {"API / Backend", "api"},
                        {"Worker / Background Job", "worker"},
                        {"Library / SDK", "library"},
                        {"Mobile App", "mobile"},
                        {"Infrastructure / IaC", "infrastructure"},
                        {"Documentation", "documentation"}
                      ]}
                    />
                    <.input
                      field={@manual_form[:notes]}
                      type="textarea"
                      label="Notes (Optional)"
                      placeholder="Component purpose, tech details, or architecture notes..."
                      rows={3}
                    />
                    <div class="flex justify-end pt-2">
                      <button type="submit" class="btn-line-filled text-xs py-2 px-4">
                        Link Repository
                      </button>
                    </div>
                  </.form>
                <% "connect" -> %>
                  <div class="space-y-4">
                    <.form
                      for={@connect_form}
                      phx-change="validate_connect"
                      phx-submit="save_vcs_connection"
                      phx-target={@myself}
                      class="space-y-3"
                    >
                      <div class="grid grid-cols-1 gap-3">
                        <.input
                          field={@connect_form[:provider]}
                          type="select"
                          label="VCS Provider"
                          options={[
                            {"Bitbucket Cloud", "bitbucket"},
                            {"GitHub", "github"},
                            {"GitLab", "gitlab"}
                          ]}
                        />

                        <% current_provider = to_string(@connect_form[:provider].value || "bitbucket") %>

                        <%= case current_provider do %>
                          <% "bitbucket" -> %>
                            <div class="text-xs text-neutral-600 dark:text-neutral-400 bg-neutral-50 dark:bg-neutral-800/50 p-3 border border-neutral-200 dark:border-neutral-700 leading-relaxed rounded">
                              <p class="font-medium text-neutral-800 dark:text-neutral-200 mb-1">
                                Bitbucket Cloud Access Token
                              </p>
                              <p class="text-[11px]">
                                Create a <em>Repository Access Token</em>
                                (single repo) or <em>Workspace Access Token</em>
                                (all repos, premium plan)
                                with <code>repository:read</code>
                                scope.
                              </p>
                            </div>

                            <.input
                              field={@connect_form[:workspace]}
                              label="Workspace Slug"
                              placeholder="e.g. my-workspace (from bitbucket.org/my-workspace)"
                              required
                            />
                            <.input
                              field={@connect_form[:token_type]}
                              type="select"
                              label="Token Scope"
                              options={[
                                {"Workspace Access Token (premium)", "workspace"},
                                {"Repository Access Token (single repo)", "repository"}
                              ]}
                            />
                            <%= if @connect_form[:token_type].value == "repository" do %>
                              <.input
                                field={@connect_form[:repo_slug]}
                                label="Repository Slug"
                                placeholder="e.g. my-repo (from bitbucket.org/workspace/my-repo)"
                                required
                              />
                            <% end %>
                            <.input
                              field={@connect_form[:token]}
                              type="password"
                              label="Access Token"
                              placeholder="Bitbucket Access Token"
                              required
                            />
                          <% "github" -> %>
                            <div class="text-xs text-neutral-600 dark:text-neutral-400 bg-neutral-50 dark:bg-neutral-800/50 p-3 border border-neutral-200 dark:border-neutral-700 leading-relaxed rounded">
                              <p class="font-medium text-neutral-800 dark:text-neutral-200 mb-1">
                                GitHub (Personal Access Token)
                              </p>
                              <p class="text-[11px]">
                                Create a Personal Access Token (classic with <code>repo</code>
                                scope, or fine-grained token with Repository permissions &rarr; Contents: Read).
                                <span class="text-amber-700 dark:text-amber-400 font-medium">
                                  Username is NOT needed.
                                </span>
                              </p>
                            </div>

                            <.input
                              field={@connect_form[:workspace]}
                              label="Organization or Account Username"
                              placeholder="e.g. my-org (or your GitHub username)"
                              required
                            />
                            <.input
                              field={@connect_form[:token]}
                              type="password"
                              label="Personal Access Token (PAT)"
                              placeholder="ghp_... or github_pat_..."
                              required
                            />
                          <% "gitlab" -> %>
                            <div class="text-xs text-neutral-600 dark:text-neutral-400 bg-neutral-50 dark:bg-neutral-800/50 p-3 border border-neutral-200 dark:border-neutral-700 leading-relaxed rounded">
                              <p class="font-medium text-neutral-800 dark:text-neutral-200 mb-1">
                                GitLab (Project, Group, or Personal Access Token)
                              </p>
                              <p class="text-[11px]">
                                Create an Access Token with <code>read_api</code>
                                and <code>read_repository</code>
                                scopes.
                                Supports both gitlab.com and self-hosted instances.
                                <span class="text-amber-700 dark:text-amber-400 font-medium">
                                  Username is NOT needed.
                                </span>
                              </p>
                            </div>

                            <.input
                              field={@connect_form[:workspace]}
                              label="Group Path or Project Namespace"
                              placeholder="e.g. my-group"
                              required
                            />
                            <.input
                              field={@connect_form[:token]}
                              type="password"
                              label="Access Token"
                              placeholder="glpat-..."
                              required
                            />
                            <.input
                              field={@connect_form[:base_url]}
                              label="Self-Hosted API URL (Optional)"
                              placeholder="https://gitlab.example.com/api/v4 (leave blank for gitlab.com)"
                            />
                        <% end %>
                      </div>

                      <%= if @vcs_error do %>
                        <div class="p-3 text-xs text-red-700 bg-red-50 border border-red-200 dark:bg-red-950/40 dark:text-red-300 dark:border-red-900">
                          {@vcs_error}
                        </div>
                      <% end %>

                      <div class="flex justify-end pt-2">
                        <button type="submit" class="btn-line-filled text-xs py-2 px-4">
                          Save Connection
                        </button>
                      </div>
                    </.form>
                  </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
