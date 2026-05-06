defmodule RavnerWeb.DomainLive.Show do
  @moduledoc """
  LiveView for the domain details page.
  Displays metadata, scan results, and allows triggering individual or bulk scans.
  """
  use RavnerWeb, :live_view

  require Logger

  alias Ravner.Domains
  alias Ravner.Inventory
  alias Ravner.Repo
  alias Ravner.Scans
  alias Ravner.Scans.SecurityRunner
  alias Ravner.SecurityScans

  # Two-part TLDs for root domain extraction (same logic as Balebos)
  @two_part_tlds ~w(co.uk com.au co.nz co.za com.br co.in org.uk me.uk net.uk co.jp)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:scanning, false)
     |> assign(:pending_scans, 0)
     |> assign(:lifecycle_menu_open, false)
     |> assign(:projects, Inventory.list_projects())
     |> assign(:brands, Inventory.list_brands())
     |> assign(:orgs, Inventory.list_organizations())
     |> assign(:latest_security_scan, nil)
     |> assign(:running_security_scan, nil)
     |> assign(:latest_failed_security_scan, nil)
     |> assign(:severity_counts, %{critical: 0, high: 0, medium: 0, low: 0})}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    # Ensure no hanging "running" scans clutter the UI
    SecurityScans.cleanup_stale_scans()

    domain = Domains.get_domain_with_preloads!(id)

    {:noreply,
     socket
     |> assign(:page_title, domain.name)
     |> assign(:domain, domain)
     |> assign(:scan_results, nil)
     |> assign(:scanning, false)
     |> assign(:pending_scans, 0)
     |> assign(:domain_class, compute_domain_class(domain))
     |> refresh_security_scan_assigns()}
  end

  # ---------------------------------------------------------------------------
  # Scan & Update events (handle_event/3)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("scan_all", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("scan_all", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()

    socket =
      socket
      |> assign(:scanning, true)
      |> assign(:pending_scans, 4)

    start_scan_tasks(liveview_pid, domain_id)

    {:noreply, socket}
  end

  def handle_event("scan_all_subdomains", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("scan_all_subdomains", _, socket) do
    domain = socket.assigns.domain
    liveview_pid = self()

    case domain.subdomains do
      [] ->
        {:noreply, socket}

      subdomains ->
        subdomain_count = length(subdomains)

        socket =
          socket
          |> assign(:scanning, true)
          |> assign(:pending_scans, subdomain_count * 4)

        Enum.each(subdomains, &start_scan_tasks(liveview_pid, &1.id))

        {:noreply, socket}
    end
  end

  def handle_event("scan_subdomains", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("scan_subdomains", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()
    socket = assign(socket, :scanning, true)

    Task.start(fn ->
      result = Scans.run_subdomain_scan(domain_id)
      send(liveview_pid, {:scan_done, :subdomains, result})
    end)

    {:noreply, socket}
  end

  def handle_event("scan_httpx", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("scan_httpx", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()
    socket = assign(socket, :scanning, true)

    Task.start(fn ->
      result = Scans.run_httpx_scan(domain_id)
      send(liveview_pid, {:scan_done, :httpx, result})
    end)

    {:noreply, socket}
  end

  def handle_event("scan_dnsx", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("scan_dnsx", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()
    socket = assign(socket, :scanning, true)

    Task.start(fn ->
      result = Scans.run_dnsx_scan(domain_id)
      send(liveview_pid, {:scan_done, :dnsx, result})
    end)

    {:noreply, socket}
  end

  def handle_event("scan_rdap", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("scan_rdap", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()
    socket = assign(socket, :scanning, true)

    Task.start(fn ->
      result = Scans.run_rdap_scan(domain_id)
      send(liveview_pid, {:scan_done, :rdap, result})
    end)

    {:noreply, socket}
  end

  # ─── Security scan (lean: httpx → naabu → nuclei) ─────────────────────────

  def handle_event("run_security_scan", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("run_security_scan", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()

    if socket.assigns.running_security_scan do
      {:noreply, put_flash(socket, :error, "A security scan is already in progress.")}
    else
      case SecurityRunner.run_security_scan(domain_id, liveview_pid) do
        {:ok, _scan} ->
          {:noreply, refresh_security_scan_assigns(socket)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    end
  end

  def handle_event("clear_scans", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role != :admin do
    {:noreply, put_flash(socket, :error, "Admin access required.")}
  end

  def handle_event("clear_scans", _, socket) do
    domain_id = socket.assigns.domain.id
    SecurityScans.clear_running_scans(domain_id)

    {:noreply,
     socket
     |> assign(:scanning, false)
     |> refresh_security_scan_assigns()
     |> put_flash(:info, "Running scans cleared.")}
  end

  def handle_event("delete_scan", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role != :admin do
    {:noreply, put_flash(socket, :error, "Admin access required.")}
  end

  def handle_event("delete_scan", %{"id" => scan_id}, socket) do
    scan_id = String.to_integer(scan_id)

    case Repo.get(Ravner.SecurityScans.SecurityScan, scan_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Scan not found.")}

      scan ->
        SecurityScans.delete_scan(scan)
        {:noreply, refresh_security_scan_assigns(socket)}
    end
  end

  def handle_event("set_lifecycle", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("set_lifecycle", %{"state" => state}, socket) do
    domain = socket.assigns.domain

    case Domains.update_domain(domain, %{lifecycle_state: state}) do
      {:ok, _} ->
        domain = Domains.get_domain_with_preloads!(domain.id)

        {:noreply,
         socket
         |> assign(:domain, domain)
         |> assign(:lifecycle_menu_open, false)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update lifecycle")}
    end
  end

  def handle_event("set_project", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission.")}
  end

  def handle_event("set_project", %{"project_id" => pid}, socket) do
    domain = socket.assigns.domain
    pid = if pid == "", do: nil, else: String.to_integer(pid)

    case Domains.update_domain_with_project(domain, pid) do
      {:ok, _} ->
        domain = Domains.get_domain_with_preloads!(domain.id)

        {:noreply,
         socket
         |> assign(:domain, domain)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update project")}
    end
  end

  def handle_event("set_brand", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission.")}
  end

  def handle_event("set_brand", %{"brand_id" => bid}, socket) do
    domain = socket.assigns.domain
    bid = if bid == "", do: nil, else: String.to_integer(bid)

    attrs = build_brand_update_attrs(domain, bid)

    case Domains.update_domain(domain, attrs) do
      {:ok, _} ->
        {:noreply, assign(socket, :domain, Domains.get_domain_with_preloads!(domain.id))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update brand")}
    end
  end

  def handle_event("set_organization", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission.")}
  end

  def handle_event("set_organization", %{"organization_id" => oid}, socket) do
    domain = socket.assigns.domain
    oid = if oid == "", do: nil, else: String.to_integer(oid)

    attrs = build_org_update_attrs(domain, oid)

    case Domains.update_domain(domain, attrs) do
      {:ok, _} ->
        {:noreply, assign(socket, :domain, Domains.get_domain_with_preloads!(domain.id))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update organization")}
    end
  end

  def handle_event("toggle_lifecycle_menu", _, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, !socket.assigns.lifecycle_menu_open)}
  end

  def handle_event("close_lifecycle_menu", _, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, false)}
  end

  # ---------------------------------------------------------------------------
  # Info handlers (handle_info/2)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:scan_done, :subdomains, {:ok, results}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    {:noreply,
     socket
     |> finish_scan()
     |> assign(:scan_results, results)
     |> assign(:domain, domain)
     |> assign(:domain_class, compute_domain_class(domain))
     |> put_flash(:info, "Found #{results.found} subdomains (#{results.new} new)")}
  end

  def handle_info({:scan_done, :httpx, {:ok, %{error: kind}}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    label =
      case kind do
        :nxdomain -> "DNS resolution failed (NXDOMAIN)"
        :timeout -> "Connection timed out"
        :tls_error -> "TLS/SSL error"
        :connection_refused -> "Connection refused"
        :connection_closed -> "Connection closed"
        _ -> "Unreachable"
      end

    {:noreply,
     socket
     |> finish_scan()
     |> assign(:domain, domain)
     |> assign(:domain_class, compute_domain_class(domain))
     |> put_flash(:error, "HTTP scan error: #{label}")}
  end

  def handle_info({:scan_done, :httpx, {:ok, _}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    {:noreply,
     socket
     |> finish_scan()
     |> assign(:domain, domain)
     |> assign(:domain_class, compute_domain_class(domain))
     |> put_flash(:info, "HTTP scan completed")}
  end

  def handle_info({:scan_done, :dnsx, {:ok, _}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    {:noreply,
     socket
     |> finish_scan()
     |> assign(:domain, domain)
     |> assign(:domain_class, compute_domain_class(domain))
     |> put_flash(:info, "DNS scan completed")}
  end

  def handle_info({:scan_done, :rdap, {:ok, %{source: source}}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    source_label =
      %{
        "rdap" => "RDAP",
        "whois" => "WHOIS",
        "ns_heuristics" => "NS heuristics",
        "none" => "no data found"
      }[source] || source

    {:noreply,
     socket
     |> finish_scan()
     |> assign(:domain, domain)
     |> assign(:domain_class, compute_domain_class(domain))
     |> put_flash(:info, "Registration scan completed via #{source_label}")}
  end

  def handle_info({:scan_done, :subdomains, {:error, reason}}, socket) do
    # Subdomain scan failures are informational — no data found, not a crash
    Logger.info("Subdomain scan returned no results: #{reason}")

    {:noreply,
     socket
     |> finish_scan()
     |> put_flash(:info, "No subdomains found")}
  end

  # ─── Security scan progress & results ─────────────────────────────────────

  def handle_info({:scan_progress, _scan_id, _progress}, socket) do
    # Re-load running scan to surface latest progress in the UI.
    {:noreply, refresh_security_scan_assigns(socket)}
  end

  def handle_info({:scan_done, :security_scan, {:ok, scan}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    {:noreply,
     socket
     |> assign(:domain, domain)
     |> assign(:domain_class, compute_domain_class(domain))
     |> refresh_security_scan_assigns()
     |> put_flash(:info, "Security scan completed — #{scan.summary}")}
  end

  def handle_info({:scan_done, :security_scan, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> refresh_security_scan_assigns()
     |> put_flash(:error, "Security scan failed: #{reason}")}
  end

  def handle_info({:scan_done, _kind, {:error, reason}}, socket) when is_binary(reason) do
    {:noreply,
     socket
     |> finish_scan()
     |> put_flash(:error, reason)}
  end

  def handle_info({:scan_done, kind, result}, socket) do
    Logger.warning("Unhandled scan_done message for #{kind}: #{inspect(result)}")

    {:noreply,
     socket
     |> finish_scan()
     |> put_flash(:error, "Scan #{kind} failed or returned unexpected data.")}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp start_scan_tasks(pid, id) do
    Task.start(fn -> send(pid, {:scan_done, :dnsx, Scans.run_dnsx_scan(id)}) end)
    Task.start(fn -> send(pid, {:scan_done, :httpx, Scans.run_httpx_scan(id)}) end)
    Task.start(fn -> send(pid, {:scan_done, :rdap, Scans.run_rdap_scan(id)}) end)
    Task.start(fn -> send(pid, {:scan_done, :subdomains, Scans.run_subdomain_scan(id)}) end)
  end

  # Decrements the pending scan counter; sets scanning: false when all done
  defp finish_scan(socket) do
    pending = max(0, socket.assigns.pending_scans - 1)
    socket = assign(socket, :pending_scans, pending)

    if pending == 0 do
      assign(socket, :scanning, false)
    else
      socket
    end
  end

  # Compute domain classification from stored metadata (Balebos-style)
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

  defp build_brand_update_attrs(domain, bid) do
    attrs = %{brand_id: bid}

    if bid do
      org = domain.organization

      if org && org.brand_id && org.brand_id != bid do
        Map.merge(attrs, %{organization_id: nil, project_id: nil})
      else
        project = domain.project

        if project do
          proj_org = Repo.get(Ravner.Inventory.Organization, project.organization_id)

          if proj_org && proj_org.brand_id && proj_org.brand_id != bid do
            Map.merge(attrs, %{project_id: nil})
          else
            attrs
          end
        else
          attrs
        end
      end
    else
      attrs
    end
  end

  defp build_org_update_attrs(domain, oid) do
    attrs = %{organization_id: oid}

    attrs =
      if oid do
        org = Repo.get(Ravner.Inventory.Organization, oid)
        if org && org.brand_id, do: Map.put(attrs, :brand_id, org.brand_id), else: attrs
      else
        attrs
      end

    if domain.project && domain.project.organization_id != oid do
      Map.put(attrs, :project_id, nil)
    else
      attrs
    end
  end

  # Returns the external redirect target domain if final_url points outside the current root domain
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

  # Loads the current security-scan related assigns (latest completed,
  # currently running, latest failure when no completed exists, severity
  # counts) from the database. Called from mount, after every scan event,
  # and after manual delete/clear actions.
  defp refresh_security_scan_assigns(socket) do
    domain_id = socket.assigns.domain.id

    latest = SecurityScans.latest_completed_scan(domain_id)
    running = SecurityScans.running_scan(domain_id)

    failed =
      if latest == nil and running == nil do
        SecurityScans.latest_failed_scan(domain_id)
      end

    socket
    |> assign(:latest_security_scan, latest)
    |> assign(:running_security_scan, running)
    |> assign(:latest_failed_security_scan, failed)
    |> assign(:severity_counts, SecurityScans.severity_counts_for_domain(domain_id))
  end

  # Returns the severity badges in fixed order so the row stays visually
  # consistent across domains. Each tuple: {label, count, active CSS classes}.
  defp severity_badges(counts) do
    [
      {"critical", counts.critical, "bg-red-50 text-red-600"},
      {"high", counts.high, "bg-orange-50 text-orange-600"},
      {"medium", counts.medium, "bg-yellow-50 text-yellow-700"},
      {"low", counts.low, "bg-blue-50 text-blue-600"}
    ]
  end

  # Maps the running scan's progress percentage to a human phase label so the
  # progress bar can describe what's happening end-to-end.
  defp scan_phase_label(progress) when is_integer(progress) do
    cond do
      progress < 30 -> "Tech detection"
      progress < 55 -> "Port discovery"
      progress < 90 -> "Vulnerability scan"
      true -> "Finalizing"
    end
  end

  defp scan_phase_label(_), do: "Starting"

  defp lifecycle_color(:active), do: "bg-green-500"
  defp lifecycle_color(:under_review), do: "bg-yellow-500"
  defp lifecycle_color(:insecure), do: "bg-amber-600"
  defp lifecycle_color(:redirect), do: "bg-cyan-500"
  defp lifecycle_color(:deprecated), do: "bg-orange-500"
  defp lifecycle_color(:decommissioned), do: "bg-red-500"
  defp lifecycle_color(:abandoned), do: "bg-neutral-400"
  defp lifecycle_color(_), do: "bg-neutral-400"

  defp lifecycle_options do
    [
      {:active, "Active", "bg-green-500"},
      {:under_review, "Under review", "bg-yellow-500"},
      {:insecure, "Insecure HTTP", "bg-amber-600"},
      {:redirect, "Redirect", "bg-cyan-500"},
      {:deprecated, "Deprecated", "bg-orange-500"},
      {:decommissioned, "Decommissioned", "bg-red-500"},
      {:abandoned, "Abandoned", "bg-neutral-400"}
    ]
  end
end
