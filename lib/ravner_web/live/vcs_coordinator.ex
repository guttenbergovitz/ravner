defmodule RavnerWeb.VcsCoordinator do
  @moduledoc """
  Shared VCS operations coordinator for LiveViews and LiveComponents.
  Eliminates duplication of sync, scan, connection, and modal logic across:
  - DomainLive.VcsPanel (LiveComponent)
  - OwnershipLive.ProjectShow (LiveView)
  - AdminLive.Repositories (LiveView)
  """

  alias Ravner.Integrations.VCS
  alias Ravner.Inventory
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  # ─── Initial Assigns for VCS Modal ───────────────────────────────────────────

  @doc """
  Returns initial assigns for VCS modal state.
  Call in mount/3 to set up modal-related assigns.
  """
  def initial_assigns do
    %{
      linking_repo?: false,
      modal_mode: "browse",
      active_vcs: nil,
      active_vcs_list: [],
      browse_provider: "bitbucket",
      selected_provider: "bitbucket",
      vcs_repos: [],
      vcs_filtered_repos: [],
      vcs_loading?: false,
      vcs_search_query: "",
      vcs_error: nil
    }
  end

  # ─── Modal Open/Close ────────────────────────────────────────────────────────

  @doc """
  Opens link repository modal with VCS state.
  Returns {:noreply, socket} or {:load_repos, socket, provider} if repos need loading.
  """
  def handle_open_link_repo(socket, opts \\ []) do
    project_repos = Keyword.get(opts, :project_repos, [])
    active_list = VCS.list_active_vcs()
    current_provider = socket.assigns[:browse_provider] || "bitbucket"
    active_vcs = VCS.safe_active_vcs(current_provider) || List.first(active_list)
    active_provider = if active_vcs, do: active_vcs.provider, else: current_provider

    default_mode =
      cond do
        project_repos != [] -> "project"
        active_vcs -> "browse"
        true -> "manual"
      end

    socket =
      socket
      |> assign(:linking_repo?, true)
      |> assign(:active_vcs, active_vcs)
      |> assign(:active_vcs_list, active_list)
      |> assign(:browse_provider, active_provider)
      |> assign(:vcs_search_query, "")
      |> assign(:vcs_error, nil)
      |> assign(:modal_mode, default_mode)

    if default_mode == "browse" && active_vcs do
      {:load_repos, socket, active_provider}
    else
      {:noreply, socket}
    end
  end

  @doc """
  Closes link repository modal.
  """
  def handle_close_link_repo(socket) do
    {:noreply, assign(socket, :linking_repo?, false)}
  end

  @doc """
  Switches modal mode (browse, manual, connect, project).
  Returns {:noreply, socket} or {:load_repos, socket, provider}.
  """
  def handle_switch_modal_mode(socket, mode) do
    socket = assign(socket, :modal_mode, mode)

    if mode == "browse" && socket.assigns.active_vcs && socket.assigns.vcs_repos == [] do
      provider = socket.assigns[:browse_provider] || "bitbucket"
      {:load_repos, socket, provider}
    else
      {:noreply, socket}
    end
  end

  @doc """
  Switches browse provider and triggers repo load if VCS is active.
  Returns {:noreply, socket} or {:load_repos, socket, provider}.
  """
  def handle_select_browse_provider(socket, provider) do
    active_vcs = VCS.safe_active_vcs(provider)

    socket =
      socket
      |> assign(:browse_provider, provider)
      |> assign(:active_vcs, active_vcs)
      |> assign(:vcs_repos, [])
      |> assign(:vcs_filtered_repos, [])
      |> assign(:vcs_error, nil)

    if active_vcs do
      {:load_repos, socket, provider}
    else
      {:noreply, socket}
    end
  end

  # ─── VCS Search & Filter ─────────────────────────────────────────────────────

  @doc """
  Filters loaded VCS repos by search query.
  """
  def handle_search_vcs(socket, query) do
    term = String.downcase(query)

    filtered =
      Enum.filter(socket.assigns.vcs_repos, fn r ->
        String.contains?(String.downcase(r.name), term) ||
          String.contains?(String.downcase(r.full_name), term) ||
          (r.description && String.contains?(String.downcase(r.description), term)) ||
          (r.main_language && String.contains?(String.downcase(r.main_language), term))
      end)

    {:noreply,
     socket
     |> assign(:vcs_search_query, query)
     |> assign(:vcs_filtered_repos, filtered)}
  end

  @doc """
  Loads VCS repositories from provider. Call from handle_info.
  """
  def load_vcs_repositories(socket, provider) do
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

  # ─── VCS Connection ──────────────────────────────────────────────────────────

  @doc """
  Validates connection form params.
  """
  def handle_validate_connect(socket, params) do
    provider = params["provider"] || socket.assigns[:selected_provider] || "bitbucket"

    {:noreply,
     socket
     |> assign(:selected_provider, provider)
     |> assign(:connect_form, Phoenix.Component.to_form(params, as: :connect))}
  end

  @doc """
  Saves VCS connection. Returns {:ok, socket} or {:error, socket}.
  On success, caller should trigger repo load.
  """
  def handle_save_vcs_connection(socket, params, flash_fn) do
    provider = params["provider"] || "bitbucket"
    workspace = String.trim(params["workspace"] || "")
    token_type = params["token_type"] || "workspace"
    repo_slug = String.trim(params["repo_slug"] || "")
    token = String.trim(params["token"] || "")
    base_url = String.trim(params["base_url"] || "")

    if workspace == "" or token == "" do
      {:noreply, assign(socket, :vcs_error, "Workspace/Organization and token are required.")}
    else
      settings = if base_url != "", do: %{"base_url" => base_url}, else: %{}

      attrs = %{
        name: "#{String.capitalize(provider)} (#{workspace})",
        provider: provider,
        workspace: workspace,
        token_type: token_type,
        repo_slug: if(repo_slug != "", do: repo_slug, else: nil),
        token: token,
        active: true,
        settings: settings
      }

      case VCS.create_integration(attrs) do
        {:ok, _integration} ->
          active_vcs = VCS.safe_active_vcs(provider)
          active_list = VCS.list_active_vcs()

          socket =
            socket
            |> assign(:active_vcs, active_vcs)
            |> assign(:active_vcs_list, active_list)
            |> assign(:browse_provider, provider)
            |> assign(:vcs_error, nil)
            |> assign(:modal_mode, "browse")

          msg = "#{String.capitalize(provider)} workspace '#{workspace}' connected successfully."
          {:load_repos, flash_fn.(socket, :info, msg), provider}

        {:error, changeset} ->
          {:noreply, assign(socket, :vcs_error, format_errors(changeset))}
      end
    end
  end

  # ─── Repository Sync ─────────────────────────────────────────────────────────

  @doc """
  Syncs repository metadata. Calls refresh_fn on success to update UI state.
  """
  def handle_sync_repo(socket, repo_id, flash_fn, refresh_fn) do
    repo = Inventory.get_project_repository!(repo_id)
    actor = socket.assigns.current_scope.user

    case VCS.sync_repository_metadata(repo, actor: actor) do
      {:ok, synced} ->
        socket = refresh_fn.(socket, synced)
        msg = "Repository '#{synced.external_id || synced.url}' synced successfully."
        {:noreply, flash_fn.(socket, :info, msg)}

      {:error, reason} ->
        {:noreply, flash_fn.(socket, :error, "Sync failed: #{reason}")}
    end
  end

  # ─── Repository Scan ─────────────────────────────────────────────────────────

  @doc """
  Scans repository for vulnerabilities. Calls refresh_fn on success.
  """
  def handle_scan_repo(socket, repo_id, flash_fn, refresh_fn) do
    repo = Inventory.get_project_repository!(repo_id)

    case Inventory.scan_project_repository(repo) do
      {:ok, %{repository: updated_repo, vulnerabilities: vulns}} ->
        socket = refresh_fn.(socket, updated_repo, vulns)

        msg =
          if vulns == [] do
            "Repository '#{repo.external_id || repo.url}' scanned — 0 vulnerabilities found (Clean)."
          else
            "Repository '#{repo.external_id || repo.url}' scanned — #{length(vulns)} vulnerabilities (#{updated_repo.critical_vuln_count} critical, #{updated_repo.high_vuln_count} high)."
          end

        flash_type = if vulns == [], do: :info, else: :warning
        {:noreply, flash_fn.(socket, flash_type, msg)}

      {:error, reason} ->
        {:noreply, flash_fn.(socket, :error, "Repository scan failed: #{reason}")}
    end
  end

  # ─── Helpers ─────────────────────────────────────────────────────────────────

  @doc """
  Format changeset errors for display.
  """
  def format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, errors} -> "#{field}: #{Enum.join(errors, "; ")}" end)
  end

  def format_errors(err), do: inspect(err)

  @doc """
  Standard put_flash for LiveViews.
  """
  def flash(socket, kind, msg), do: put_flash(socket, kind, msg)

  @doc """
  Component-compatible flash: sends to parent and puts on socket.
  Use in LiveComponents where put_flash alone doesn't work.
  """
  def notify_flash(socket, kind, msg) do
    send(self(), {:put_flash, kind, msg})
    put_flash(socket, kind, msg)
  end
end
