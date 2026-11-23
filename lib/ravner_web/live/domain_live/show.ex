defmodule RavnerWeb.DomainLive.Show do
  @moduledoc """
  LiveView for the domain details page.
  Coordinates metadata display, governance lifecycle transitions, tab navigation,
  and delegates domain scanning, repository VCS management, and contact assignment
  to dedicated LiveComponents and coordinator modules.
  """
  use RavnerWeb, :live_view

  require Logger

  import RavnerWeb.DomainComponents
  import RavnerWeb.DomainLive.ShowGovernanceTab
  import RavnerWeb.DomainLive.ShowTechnicalTab

  alias Ravner.A11y
  alias Ravner.Domains
  alias Ravner.Inventory
  alias Ravner.Lighthouse
  alias Ravner.SecurityScans
  alias RavnerWeb.DomainLive.ScanCoordinator

  # Two-part TLDs for root domain extraction (same logic as Balebos)
  @two_part_tlds ~w(co.uk com.au co.nz co.za com.br co.in org.uk me.uk net.uk co.jp)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_tab, :technical)
     |> assign(:scanning, false)
     |> assign(:active_scan_kind, nil)
     |> assign(:pending_scans, 0)
     |> assign(:lifecycle_menu_open, false)
     |> assign(:show_findings_modal, false)
     |> assign(:projects, [])
     |> assign(:brands, [])
     |> assign(:orgs, [])
     |> assign(:versions, [])
     |> assign(:latest_security_scan, nil)
     |> assign(:latest_breach_scan, nil)
     |> assign(:running_security_scan, nil)
     |> assign(:latest_failed_security_scan, nil)
     |> assign(:severity_counts, %{critical: 0, high: 0, medium: 0, low: 0})
     |> assign(:show_contacts_modal, false)
     |> assign(:contacts_pm_email, "")
     |> assign(:contacts_po_email, "")
     |> assign(:pm_candidates, [])
     |> assign(:po_candidates, [])
     |> assign(:filtered_pm_candidates, [])
     |> assign(:filtered_po_candidates, [])
     |> assign(:pm_search_query, "")
     |> assign(:po_search_query, "")
     |> assign(:project_team, %{pm: [], po: [], all: []})
     |> assign(:pm_person, nil)
     |> assign(:po_person, nil)
     |> assign(:escalation_chain, %{
       level_1_project: %{
         project: nil,
         pm_email: nil,
         pm_person: nil,
         po_email: nil,
         po_person: nil
       },
       level_2_organization: %{organization: nil, manager: nil},
       level_3_brand: %{brand: nil, brand_manager: nil}
     })
     |> assign(:a11y_scan, nil)
     |> assign(:a11y_running?, false)
     |> assign(:a11y_scannable?, false)
     |> assign(:lighthouse_scan, nil)
     |> assign(:lighthouse_running?, false)
     |> assign(:primary_repo, nil)
     |> assign(:domain_repos, [])
     |> assign(:project_repos, [])
     |> assign(:can_scan?, false)
     |> assign(:can_manage?, false)
     |> assign(:scan_results, nil)}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    tab =
      case params["tab"] do
        "governance" -> :governance
        "audit" -> :audit
        _ -> :technical
      end

    if socket.assigns[:domain] && to_string(socket.assigns.domain.id) == to_string(id) do
      {:noreply, assign(socket, :active_tab, tab)}
    else
      # Ensure no hanging "running" scans clutter the UI
      SecurityScans.cleanup_stale_scans()
      Lighthouse.cleanup_stale_scans()

      domain = Domains.get_domain_with_preloads!(id)

      if Ravner.Accounts.ScopeResolver.can_view_domain?(socket.assigns[:current_scope], domain) do
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Ravner.PubSub, "a11y_scan:domain:#{domain.id}")
          Phoenix.PubSub.subscribe(Ravner.PubSub, "lighthouse_scan:domain:#{domain.id}")
          Phoenix.PubSub.subscribe(Ravner.PubSub, "subdomain_scans:domain:#{domain.id}")
        end

        can_scan? =
          Ravner.Accounts.ScopeResolver.can_scan_domain?(socket.assigns[:current_scope], domain)

        can_manage? =
          Ravner.Accounts.ScopeResolver.can_manage_domain?(socket.assigns[:current_scope], domain)

        {:noreply,
         socket
         |> assign(:page_title, domain.name)
         |> assign(:active_tab, tab)
         |> assign(:projects, Inventory.list_projects(scope: socket.assigns[:current_scope]))
         |> assign(:brands, Inventory.list_brands(scope: socket.assigns[:current_scope]))
         |> assign(:orgs, Inventory.list_organizations(scope: socket.assigns[:current_scope]))
         |> assign(:can_scan?, can_scan?)
         |> assign(:can_manage?, can_manage?)
         |> assign_domain_and_governance(domain)
         |> assign(:scan_results, nil)
         |> assign(:scanning, false)
         |> assign(:active_scan_kind, nil)
         |> assign(:pending_scans, 0)
         |> assign(:domain_class, compute_domain_class(domain))
         |> assign(:a11y_scannable?, A11y.scannable?(domain))
         |> assign(:a11y_scan, A11y.latest_scan(domain.id))
         |> assign(:a11y_running?, A11y.running_scan(domain.id) != nil)
         |> assign(:lighthouse_scan, Lighthouse.latest_scan(domain.id))
         |> assign(:lighthouse_running?, Lighthouse.running_scan(domain.id) != nil)
         |> refresh_security_scan_assigns()}
      else
        {:noreply,
         socket
         |> put_flash(:error, "You do not have permission to view this domain.")
         |> push_navigate(to: ~p"/domains")}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tab & Risk Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/domains/#{socket.assigns.domain.id}?tab=#{tab}")}
  end

  @impl true
  def handle_event("recalculate_risk", _, socket) do
    domain = socket.assigns.domain

    case Ravner.Domains.recalculate_risk_score(domain.id) do
      {:ok, result} ->
        updated_domain = Domains.get_domain_with_preloads!(domain.id)

        flash_msg =
          if is_integer(result.overall_score) do
            "Cyber risk score recalculated: #{result.overall_score}/100 (#{result.grade})."
          else
            "Cyber risk scoring updated: Pending initial scans (#{result.grade})."
          end

        {:noreply,
         socket
         |> assign_domain_and_governance(updated_domain)
         |> put_flash(:info, flash_msg)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to recalculate risk score: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Governance Assignments (Project, Brand, Organization)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("set_project", %{"project_id" => pid}, socket) do
    if can_manage?(socket) do
      domain = socket.assigns.domain
      pid = if pid == "", do: nil, else: String.to_integer(pid)
      actor = socket.assigns.current_scope.user

      case Domains.assign_domain_project(domain, pid, actor: actor) do
        {:ok, _} ->
          domain = Domains.get_domain_with_preloads!(domain.id)
          {:noreply, assign_domain_and_governance(socket, domain)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update project")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    end
  end

  @impl true
  def handle_event("set_brand", %{"brand_id" => bid}, socket) do
    if can_manage?(socket) do
      domain = socket.assigns.domain
      bid = if bid == "", do: nil, else: String.to_integer(bid)
      actor = socket.assigns.current_scope.user

      case Domains.assign_domain_brand(domain, bid, actor: actor) do
        {:ok, _} ->
          {:noreply,
           assign_domain_and_governance(socket, Domains.get_domain_with_preloads!(domain.id))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update brand")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    end
  end

  @impl true
  def handle_event("set_organization", %{"organization_id" => oid}, socket) do
    if can_manage?(socket) do
      domain = socket.assigns.domain
      oid = if oid == "", do: nil, else: String.to_integer(oid)
      actor = socket.assigns.current_scope.user

      case Domains.assign_domain_organization(domain, oid, actor: actor) do
        {:ok, _} ->
          {:noreply,
           assign_domain_and_governance(socket, Domains.get_domain_with_preloads!(domain.id))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update organization")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Lifecycle Transitions (Delegated to LifecycleDropdown, with fallback)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_lifecycle_menu", _, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, !socket.assigns.lifecycle_menu_open)}
  end

  @impl true
  def handle_event("close_lifecycle_menu", _, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, false)}
  end

  @impl true
  def handle_event("set_lifecycle", %{"state" => state}, socket) do
    if can_manage?(socket) do
      domain = socket.assigns.domain
      actor = socket.assigns.current_scope.user

      case Domains.set_domain_lifecycle(domain, state, actor: actor) do
        {:ok, _} ->
          domain = Domains.get_domain_with_preloads!(domain.id)

          {:noreply,
           socket
           |> assign_domain_and_governance(domain)
           |> assign(:lifecycle_menu_open, false)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update lifecycle")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Contacts Modal Controls
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("open_contacts_modal", _params, socket) do
    if can_manage?(socket) do
      {:noreply, assign(socket, :show_contacts_modal, true)}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
    end
  end

  @impl true
  def handle_event("close_contacts_modal", _, socket) do
    {:noreply, assign(socket, :show_contacts_modal, false)}
  end

  # ---------------------------------------------------------------------------
  # Scan & Scheduling Events (Delegated to ScanCoordinator)
  # Most scan events are handled by ScanPanel LiveComponent.
  # scan_all_subdomains is used by domain_components.ex for subdomain bulk scan.
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("scan_all_subdomains", _, socket),
    do: ScanCoordinator.handle_scan_all_subdomains(socket)

  # ---------------------------------------------------------------------------
  # Info handlers (handle_info/2)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:put_flash, kind, msg}, socket) do
    {:noreply, put_flash(socket, kind, msg)}
  end

  @impl true
  def handle_info({:domain_updated, updated_domain}, socket) do
    {:noreply, assign_domain_and_governance(socket, updated_domain)}
  end

  @impl true
  def handle_info({:vcs_repo_changed, _domain_id}, socket) do
    reloaded = Domains.get_domain_with_preloads!(socket.assigns.domain.id)
    {:noreply, assign_domain_and_governance(socket, reloaded)}
  end

  @impl true
  def handle_info({:contacts_saved, updated_domain}, socket) do
    {:noreply,
     socket
     |> assign_domain_and_governance(updated_domain)
     |> assign(:show_contacts_modal, false)}
  end

  @impl true
  def handle_info(:close_contacts_modal, socket) do
    {:noreply, assign(socket, :show_contacts_modal, false)}
  end

  @impl true
  def handle_info(:refresh_security_scans, socket) do
    {:noreply,
     socket
     |> assign(:scanning, false)
     |> assign(:active_scan_kind, nil)
     |> refresh_security_scan_assigns()}
  end

  @impl true
  def handle_info({:scan_progress, _scan_id, _progress}, socket) do
    # Re-load running scan to surface latest progress in the UI.
    {:noreply, refresh_security_scan_assigns(socket)}
  end

  @impl true
  def handle_info({:scan_done, kind, result}, socket) do
    ScanCoordinator.handle_scan_done(socket, kind, result, &reload_domain(&1, []))
  end

  @impl true
  def handle_info({:bulk_scan_done, _subdomain_id, "quick", _status}, socket) do
    {:noreply,
     socket
     |> reload_domain([])
     |> ScanCoordinator.finish_scan()}
  end

  @impl true
  def handle_info({:a11y_scan_completed, scan}, socket) do
    ScanCoordinator.handle_a11y_completed(socket, scan)
  end

  @impl true
  def handle_info({:lighthouse_scan_completed, scan}, socket) do
    ScanCoordinator.handle_lighthouse_completed(socket, scan)
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp reload_domain(socket, []) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)
    assign_domain_and_governance(socket, domain)
  end

  defp reload_domain(socket, extra_preloads) do
    domain =
      socket.assigns.domain.id
      |> Domains.get_domain_with_preloads!()
      |> Ash.load!(extra_preloads, authorize?: false)

    assign_domain_and_governance(socket, domain)
  end

  defp assign_domain_and_governance(socket, domain) do
    primary_repo = Inventory.get_primary_repository_for_domain(domain)
    domain_repos = Inventory.list_all_repositories_for_domain(domain)

    project_repos =
      if domain.project_id, do: Inventory.list_project_repositories(domain.project_id), else: []

    candidates = Domains.contact_candidates(domain)

    socket
    |> assign(:domain, domain)
    |> assign(:primary_repo, primary_repo)
    |> assign(:domain_repos, domain_repos)
    |> assign(:project_repos, project_repos)
    |> assign(:versions, Domains.list_domain_versions(domain.id))
    |> assign(:project_team, Domains.project_team_candidates(domain))
    |> assign(:pm_candidates, candidates.pm_candidates)
    |> assign(:po_candidates, candidates.po_candidates)
    |> assign(:filtered_pm_candidates, candidates.pm_candidates |> Enum.take(8))
    |> assign(:filtered_po_candidates, candidates.po_candidates |> Enum.take(8))
    |> assign(:pm_person, Domains.find_person_by_email(domain.pm_email))
    |> assign(:po_person, Domains.find_person_by_email(domain.po_email))
    |> assign(:escalation_chain, Domains.domain_escalation_chain(domain))
    |> assign(:domain_class, compute_domain_class(domain))
  end

  defp refresh_security_scan_assigns(socket) do
    domain_id = socket.assigns.domain.id

    latest_sec = SecurityScans.latest_security_scan(domain_id)
    latest_breach = SecurityScans.latest_breach_scan(domain_id)
    running = SecurityScans.running_scan(domain_id)

    failed =
      if latest_sec == nil and latest_breach == nil and running == nil do
        SecurityScans.latest_failed_scan(domain_id)
      end

    socket
    |> assign(:latest_security_scan, latest_sec)
    |> assign(:latest_breach_scan, latest_breach)
    |> assign(:running_security_scan, running)
    |> assign(:latest_failed_security_scan, failed)
    |> assign(:severity_counts, SecurityScans.severity_counts_for_domain(domain_id))
  end

  defp compute_domain_class(domain) do
    classify_by_metadata(domain, domain.domain_metadata)
  end

  defp classify_by_metadata(_domain, nil), do: {:not_scanned, nil}
  defp classify_by_metadata(_domain, %{http_status: nil}), do: {:not_scanned, nil}
  defp classify_by_metadata(_domain, %{http_status: 0}), do: {:scan_error, nil}

  defp classify_by_metadata(domain, %{http_status: 200, final_url: url}) do
    case external_redirect_target(domain.name, url) do
      nil -> {:ok, nil}
      target -> {:external_redirect, target}
    end
  end

  defp classify_by_metadata(_domain, %{http_status: status, final_url: url})
       when status in 300..399 do
    {:redirect, url || "unknown"}
  end

  defp classify_by_metadata(_domain, %{http_status: status}) when status in 400..499 do
    {:client_error, status}
  end

  defp classify_by_metadata(_domain, %{http_status: status}) when status in 500..599 do
    {:server_error, status}
  end

  defp classify_by_metadata(_domain, %{http_status: status}) do
    {:other, status}
  end

  defp external_redirect_target(_domain_name, nil), do: nil

  defp external_redirect_target(domain_name, final_url) do
    current_root = extract_root_domain(domain_name)

    final_root =
      final_url
      |> URI.parse()
      |> Map.get(:host, "")
      |> kernel_to_string()
      |> extract_root_domain()

    if final_root != "" && final_root != current_root do
      final_root
    else
      nil
    end
  end

  defp kernel_to_string(nil), do: ""
  defp kernel_to_string(s), do: s

  defp extract_root_domain(host) when is_binary(host) do
    parts = host |> String.replace_prefix("www.", "") |> String.split(".")
    count = length(parts)

    cond do
      count >= 3 && two_part_tld?(parts |> Enum.take(-2) |> Enum.join(".")) ->
        parts |> Enum.take(-3) |> Enum.join(".")

      count >= 2 ->
        parts |> Enum.take(-2) |> Enum.join(".")

      true ->
        host
    end
  end

  defp extract_root_domain(_), do: ""

  defp two_part_tld?(tld), do: tld in @two_part_tlds

  defp can_manage?(socket) do
    scope = socket.assigns[:current_scope]
    domain = socket.assigns[:domain]
    Ravner.Accounts.ScopeResolver.can_manage_domain?(scope, domain)
  end
end
