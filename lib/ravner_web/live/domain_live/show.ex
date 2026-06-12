defmodule RavnerWeb.DomainLive.Show do
  @moduledoc """
  LiveView for the domain details page.
  Displays metadata, scan results, and allows triggering individual or bulk scans.
  """
  use RavnerWeb, :live_view

  require Logger

  import RavnerWeb.DomainComponents

  alias Ravner.Domains
  alias Ravner.Inventory
  alias Ravner.Scans
  alias Ravner.SecurityScans

  # Two-part TLDs for root domain extraction (same logic as Balebos)
  @two_part_tlds ~w(co.uk com.au co.nz co.za com.br co.in org.uk me.uk net.uk co.jp)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:scanning, false)
     |> assign(:active_scan_kind, nil)
     |> assign(:pending_scans, 0)
     |> assign(:lifecycle_menu_open, false)
     |> assign(:show_findings_modal, false)
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
     |> assign(:active_scan_kind, nil)
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
    user_id = socket.assigns.current_scope.user.id

    socket =
      socket
      |> assign(:scanning, true)
      |> assign(:active_scan_kind, :all)
      |> assign(:pending_scans, 4)

    start_scan_tasks(liveview_pid, domain_id, user_id)

    {:noreply, socket}
  end

  def handle_event("scan_all_subdomains", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("scan_all_subdomains", _, socket) do
    domain = socket.assigns.domain
    liveview_pid = self()
    user_id = socket.assigns.current_scope.user.id

    case domain.subdomains do
      [] ->
        {:noreply, socket}

      subdomains ->
        subdomain_count = length(subdomains)

        socket =
          socket
          |> assign(:scanning, true)
          |> assign(:active_scan_kind, :all_subdomains)
          |> assign(:pending_scans, subdomain_count * 4)

        Enum.each(subdomains, &start_scan_tasks(liveview_pid, &1.id, user_id))

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
    user_id = socket.assigns.current_scope.user.id

    socket =
      socket
      |> assign(:scanning, true)
      |> assign(:active_scan_kind, :subdomains)

    start_background_scan(user_id, fn ->
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
    user_id = socket.assigns.current_scope.user.id

    socket =
      socket
      |> assign(:scanning, true)
      |> assign(:active_scan_kind, :httpx)

    start_background_scan(user_id, fn ->
      result = Scans.Http.run_httpx_scan(domain_id)
      send(liveview_pid, {:scan_done, :httpx, result})
    end)

    {:noreply, socket}
  end

  def handle_event("scan_deep_tech", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("scan_deep_tech", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()
    user_id = socket.assigns.current_scope.user.id

    socket =
      socket
      |> assign(:scanning, true)
      |> assign(:active_scan_kind, :deep_tech)

    start_background_scan(user_id, fn ->
      result = Scans.Http.run_deep_tech_scan(domain_id)
      send(liveview_pid, {:scan_done, :deep_tech, result})
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
    user_id = socket.assigns.current_scope.user.id

    socket =
      socket
      |> assign(:scanning, true)
      |> assign(:active_scan_kind, :dnsx)

    start_background_scan(user_id, fn ->
      result = Scans.Dns.run(domain_id)
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
    user_id = socket.assigns.current_scope.user.id

    socket =
      socket
      |> assign(:scanning, true)
      |> assign(:active_scan_kind, :rdap)

    start_background_scan(user_id, fn ->
      result = Scans.Whois.run_rdap_scan(domain_id)
      send(liveview_pid, {:scan_done, :rdap, result})
    end)

    {:noreply, socket}
  end

  # ─── Security scan events have been moved to SecurityPostureComponent ─────

  def handle_event("update_scheduling", _params, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("update_scheduling", params, socket) do
    domain = socket.assigns.domain

    attrs = %{
      scan_interval_days: parse_interval(params["scan_interval_days"]),
      heartbeat_interval_minutes: parse_interval(params["heartbeat_interval_minutes"]),
      http_scan_interval_days: parse_interval(params["http_scan_interval_days"]),
      dns_scan_interval_days: parse_interval(params["dns_scan_interval_days"])
    }

    case Domains.upsert_domain_metadata(domain.id, attrs) do
      {:ok, _metadata} ->
        domain = Domains.get_domain_with_preloads!(domain.id)
        {:noreply, assign(socket, :domain, domain) |> put_flash(:info, "Scheduling updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update scheduling")}
    end
  end

  def handle_event("set_lifecycle", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("set_lifecycle", %{"state" => state}, socket) do
    domain = socket.assigns.domain
    actor = socket.assigns.current_scope.user

    case Domains.set_domain_lifecycle(domain, state, actor: actor) do
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
    actor = socket.assigns.current_scope.user

    case Domains.assign_domain_project(domain, pid, actor: actor) do
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
    actor = socket.assigns.current_scope.user

    case Domains.assign_domain_brand(domain, bid, actor: actor) do
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
    actor = socket.assigns.current_scope.user

    case Domains.assign_domain_organization(domain, oid, actor: actor) do
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
  def handle_info(:refresh_security_scans, socket) do
    {:noreply,
     socket
     |> assign(:scanning, false)
     |> assign(:active_scan_kind, nil)
     |> refresh_security_scan_assigns()}
  end

  @impl true
  def handle_info({:scan_done, :subdomains, {:ok, results}}, socket) do
    {:noreply,
     socket
     |> reload_domain([])
     |> finish_scan()
     |> assign(:scan_results, results)
     |> put_flash(:info, "Found #{results.found} subdomains (#{results.new} new)")}
  end

  def handle_info({:scan_done, :httpx, {:ok, %{error: kind}}}, socket) do
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
     |> reload_domain([])
     |> finish_scan()
     |> put_flash(:error, "HTTP scan error: #{label}")}
  end

  def handle_info({:scan_done, :httpx, {:ok, _}}, socket) do
    {:noreply,
     socket
     |> reload_domain([])
     |> finish_scan()
     |> put_flash(:info, "HTTP scan completed")}
  end

  def handle_info({:scan_done, :deep_tech, {:ok, results}}, socket) do
    suffix =
      if results.errors == [] do
        ""
      else
        " (#{length(results.errors)} tool warnings)"
      end

    {:noreply,
     socket
     |> reload_domain([])
     |> finish_scan()
     |> put_flash(
       :info,
       "Deep tech scan completed: #{results.evidence} findings, #{results.urls} URLs#{suffix}"
     )}
  end

  def handle_info({:scan_done, :dnsx, {:ok, _}}, socket) do
    {:noreply,
     socket
     |> reload_domain([])
     |> finish_scan()
     |> put_flash(:info, "DNS scan completed")}
  end

  def handle_info({:scan_done, :rdap, {:ok, %{source: source}}}, socket) do
    source_label =
      %{
        "rdap" => "RDAP",
        "whois" => "WHOIS",
        "ns_heuristics" => "NS heuristics",
        "none" => "no data found"
      }[source] || source

    {:noreply,
     socket
     |> reload_domain([])
     |> finish_scan()
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
    {:noreply,
     socket
     |> reload_domain([])
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

  defp infrastructure_metadata?(domain) do
    metadata = domain.domain_metadata

    (metadata &&
       (metadata.hosting_platform || metadata.asn_org ||
          populated?(metadata.tech_stack) ||
          populated?(metadata.js_assets) ||
          populated?(metadata.open_ports))) ||
      populated?(domain.tech_evidence) ||
      populated?(domain.discovered_urls)
  end

  defp populated?(value), do: is_list(value) && value != []

  defp start_scan_tasks(pid, id, user_id) do
    start_background_scan(user_id, fn ->
      results = Scans.run_quick_scan(id)

      send(pid, {:scan_done, :dnsx, Map.fetch!(results, :dnsx)})
      send(pid, {:scan_done, :httpx, Map.fetch!(results, :httpx)})
      send(pid, {:scan_done, :rdap, Map.fetch!(results, :rdap)})
      send(pid, {:scan_done, :subdomains, Map.fetch!(results, :subdomains)})
    end)
  end

  defp start_background_scan(user_id, fun) when is_function(fun, 0) do
    Task.Supervisor.start_child(Ravner.ScanTaskSupervisor, fn ->
      if user_id, do: Ravner.ActivityLog.set_user(user_id)
      fun.()
    end)
  end

  # Decrements the pending scan counter; sets scanning: false when all done
  defp finish_scan(socket) do
    pending = max(0, socket.assigns.pending_scans - 1)
    socket = assign(socket, :pending_scans, pending)

    if pending == 0 do
      socket
      |> assign(:scanning, false)
      |> assign(:active_scan_kind, nil)
    else
      socket
    end
  end

  # Reloads domain with template-required associations
  defp reload_domain(socket, extra_preloads) do
    preloads =
      [
        :parent_domain,
        :domain_metadata,
        :domain_tags,
        :project,
        :brand,
        :organization,
        :dns_records,
        :tech_evidence,
        :discovered_urls,
        subdomains: [:domain_metadata]
      ] ++ extra_preloads

    domain =
      Domains.get_domain!(socket.assigns.domain.id)
      |> Ash.load!(preloads)

    socket
    |> assign(:domain, domain)
    |> assign(:domain_class, compute_domain_class(domain))
  end

  defp parse_interval(""), do: nil

  defp parse_interval(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_interval(_), do: nil

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
end
