defmodule RavnerWeb.DomainLive.Index do
  @moduledoc """
  LiveView for the domain listing page.
  Supports filtering, pagination, selection mode, and bulk operations.
  """
  use RavnerWeb, :live_view

  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Inventory
  alias Ravner.Scans

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: RavnerWeb.Endpoint.subscribe("scans")

    {:ok,
     socket
     |> assign_initial_state()
     |> allow_upload(:domains_file,
       accept: ~w(.txt),
       max_entries: 1,
       max_file_size: 5_000_000,
       auto_upload: true
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket = apply_action(socket, socket.assigns.live_action, params)

    if socket.assigns.live_action in [:new, :edit, :import] and
         not editor?(socket.assigns.current_scope) do
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permission to perform this action.")
       |> push_patch(to: ~p"/domains")}
    else
      {:noreply, socket}
    end
  end

  # ── Event handlers (handle_event/3) ─────────────────────────────────────────

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    params = build_params(socket, search: query, page: 1)
    {:noreply, socket |> assign(:suggestions, []) |> push_patch(to: ~p"/domains?#{params}")}
  end

  def handle_event("suggest", %{"search" => query}, socket) do
    suggestions = Domains.suggest_domains(query)
    {:noreply, assign(socket, :suggestions, suggestions)}
  end

  def handle_event("suggest", _params, socket) do
    {:noreply, assign(socket, :suggestions, [])}
  end

  def handle_event("dismiss_suggestions", _params, socket) do
    {:noreply, assign(socket, :suggestions, [])}
  end

  def handle_event("clear_search", _params, socket) do
    params = build_params(socket, search: "", page: 1)
    {:noreply, socket |> assign(:suggestions, []) |> push_patch(to: ~p"/domains?#{params}")}
  end

  def handle_event("select_suggestion", %{"name" => name}, socket) do
    params = build_params(socket, search: name, page: 1)
    {:noreply, socket |> assign(:suggestions, []) |> push_patch(to: ~p"/domains?#{params}")}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/domains")}
  end

  def handle_event("filter_ip", %{"ip" => ip}, socket) do
    params = build_params(socket, ip: ip, page: 1)
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  def handle_event("clear_ip", _params, socket) do
    params = build_params(socket, ip: "")
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  def handle_event("toggle_facet", %{"type" => type, "id" => id}, socket) do
    field =
      case type do
        "lifecycle" -> :lifecycle_filter
        "brand" -> :brand_filter
        "org" -> :org_filter
        "project" -> :project_filter
      end

    current_val = socket.assigns[field] || []
    id_val = if type == "lifecycle", do: String.to_atom(id), else: String.to_integer(id)

    new_val =
      if id_val in current_val do
        List.delete(current_val, id_val)
      else
        [id_val | current_val]
      end

    overrides =
      case type do
        "lifecycle" -> [lifecycle: new_val]
        "brand" -> [brand_id: new_val]
        "org" -> [organization_id: new_val]
        "project" -> [project_id: new_val]
      end

    params = build_params(socket, overrides ++ [page: 1])
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  def handle_event("clear_filter", %{"type" => type}, socket) do
    overrides =
      case type do
        "lifecycle" -> [lifecycle: []]
        "brand" -> [brand_id: []]
        "org" -> [organization_id: []]
        "project" -> [project_id: []]
      end

    params = build_params(socket, overrides ++ [page: 1])
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  def handle_event("toggle_empty_facets", _params, socket) do
    {:noreply, assign(socket, :show_empty_facets, !socket.assigns.show_empty_facets)}
  end

  def handle_event("paginate", %{"page" => page_str}, socket) do
    page = page_str |> Integer.parse() |> elem(0)
    params = build_params(socket, page: page)
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  def handle_event("toggle_export_subs", _params, socket) do
    {:noreply, assign(socket, :export_include_subs, !socket.assigns.export_include_subs)}
  end

  def handle_event("enter_selection_mode", _params, socket) do
    {:noreply, assign(socket, :selection_mode, true)}
  end

  def handle_event("exit_selection_mode", _params, socket) do
    {:noreply,
     socket
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:include_subdomains, false)
     |> assign(:bulk_action, nil)
     |> assign(:bulk_lifecycle_menu_open, false)
     |> assign(:scanning_ids, MapSet.new())
     |> assign(:ip_filter, "")
     |> assign(:export_include_subs, false)}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected = socket.assigns.selected_ids
    new_selected = toggle_mapset(selected, id)

    {:noreply, assign(socket, :selected_ids, new_selected)}
  end

  def handle_event("select_all_matching", _params, socket) do
    params = Map.new(build_params(socket))
    domains = Domains.list_domains_filtered_all(Map.to_list(params))
    ids = Enum.map(domains, &to_string(&1.id))
    {:noreply, assign(socket, :selected_ids, MapSet.new(ids))}
  end

  def handle_event("select_visible", _params, socket) do
    ids = Enum.map(socket.assigns.domains, &to_string(&1.id))
    {:noreply, assign(socket, :selected_ids, MapSet.new(ids))}
  end

  def handle_event("toggle_include_subdomains", _params, socket) do
    {:noreply, assign(socket, :include_subdomains, !socket.assigns.include_subdomains)}
  end

  def handle_event("open_lifecycle_menu", %{"id" => id}, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, id)}
  end

  def handle_event("close_lifecycle_menu", _params, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, nil)}
  end

  def handle_event("set_lifecycle", %{"id" => id, "state" => state}, socket) do
    domain = Domains.get_domain!(id)
    Domains.update_domain(domain, %{lifecycle_state: state})

    {:noreply,
     socket
     |> assign(:lifecycle_menu_open, nil)
     |> put_flash(:info, "Lifecycle updated")}
  end

  def handle_event("toggle_bulk_lifecycle_menu", _params, socket) do
    {:noreply,
     assign(socket, :bulk_lifecycle_menu_open, !socket.assigns.bulk_lifecycle_menu_open)}
  end

  def handle_event("close_bulk_lifecycle_menu", _params, socket) do
    {:noreply, assign(socket, :bulk_lifecycle_menu_open, false)}
  end

  def handle_event("bulk_action_confirm", %{"action" => action}, socket) do
    {:noreply, assign(socket, :bulk_action, String.to_atom(action))}
  end

  def handle_event("bulk_action_confirm", %{"lifecycle" => state}, socket) do
    {:noreply, assign(socket, :bulk_action, {:lifecycle, String.to_atom(state)})}
  end

  def handle_event("bulk_action_cancel", _params, socket) do
    {:noreply, assign(socket, :bulk_action, nil)}
  end

  def handle_event("bulk_action_execute", _params, socket) do
    case socket.assigns.bulk_action do
      :delete -> execute_bulk_delete(socket)
      :scan -> execute_bulk_scan(socket)
      {:lifecycle, state} -> execute_bulk_lifecycle(socket, state)
    end
  end

  def handle_event("quick_scan", %{"id" => id}, socket) do
    domain_id = String.to_integer(id)

    Task.start(fn ->
      Scans.run_dnsx_scan(domain_id)
      Scans.run_httpx_scan(domain_id)
      Scans.run_rdap_scan(domain_id)
      Scans.run_subdomain_scan(domain_id)
      send(socket.parent_pid, {:quick_scan_done, domain_id})
    end)

    {:noreply, assign(socket, :scanning_ids, MapSet.put(socket.assigns.scanning_ids, id))}
  end

  def handle_event("scan_visible", _, socket) do
    ids = socket.assigns.domains |> Enum.map(& &1.id)
    include_subdomains = socket.assigns.include_subdomains

    execute_scan_on_ids(socket, ids, include_subdomains)
  end

  def handle_event("ip_copied", %{"ip" => ip}, socket) do
    {:noreply, put_flash(socket, :info, "Copied IP: #{ip}")}
  end

  @impl true
  def handle_info({:quick_scan_done, domain_id}, socket) do
    # Trigger a data refresh
    params = build_params(socket)

    {:noreply,
     socket
     |> assign(:scanning_ids, MapSet.delete(socket.assigns.scanning_ids, "#{domain_id}"))
     |> push_patch(to: ~p"/domains?#{params}")}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp assign_initial_state(socket) do
    socket
    |> assign(:expanded_domains, MapSet.new())
    |> assign(:lifecycle_menu_open, nil)
    |> assign(:importing, false)
    |> assign(:suggestions, [])
    |> assign(:selection_mode, false)
    |> assign(:selected_ids, MapSet.new())
    |> assign(:include_subdomains, false)
    |> assign(:bulk_action, nil)
    |> assign(:bulk_lifecycle_menu_open, false)
    |> assign(:scanning_ids, MapSet.new())
    |> assign(:ip_filter, "")
    |> assign(:export_include_subs, false)
    |> assign(:project_filter, [])
    |> assign(:org_filter, [])
    |> assign(:brand_filter, [])
    |> assign(:lifecycle_filter, [])
    |> assign(:show_empty_facets, false)
    |> assign(:facets, %{lifecycle: [], brands: [], organizations: [], projects: []})
  end

  defp apply_action(socket, :index, params) do
    filters = parse_filters(params)
    filter_list = Map.to_list(filters)
    result = Domains.list_domains_filtered(filter_list)
    facets = Domains.get_facet_counts(filter_list)

    # Re-apply subdomain metadata preload for any currently expanded domains
    expanded = socket.assigns[:expanded_domains] || MapSet.new()
    domains = apply_metadata_preload(result.domains, expanded)

    socket
    |> assign_index_state(result, domains, filters, facets)
    |> maybe_clear_selection(filters)
  end

  defp apply_action(socket, :new, _params) do
    changeset = Domains.change_domain(%Domain{})

    socket
    |> assign(:page_title, "New Domain")
    |> assign(:domain, %Domain{})
    |> assign(:form, to_form(changeset))
    |> assign(:projects, Inventory.list_projects())
    |> assign(:orgs, Inventory.list_organizations())
    |> assign(:brands, Inventory.list_brands())
  end

  defp apply_action(socket, :import, _params) do
    socket
    |> assign(:page_title, "Import Domains")
    |> assign(:domain, nil)
    |> assign(:import_results, nil)
    |> assign(:importing, false)
  end

  defp assign_index_state(socket, result, domains, filters, facets) do
    socket
    |> assign(:page_title, "Domains")
    |> assign(:domain, nil)
    |> assign(:domains, domains)
    |> assign(:total, result.total)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:search, filters.search)
    |> assign(:ip_filter, filters.ip)
    |> assign(:lifecycle_filter, filters.lifecycle)
    |> assign(:project_filter, filters.project_id)
    |> assign(:org_filter, filters.org_id)
    |> assign(:brand_filter, filters.brand_id)
    |> assign(:facets, facets)
  end

  defp maybe_clear_selection(socket, filters) do
    if filters_changed?(socket, filters) do
      assign(socket, :selected_ids, MapSet.new())
    else
      socket
    end
  end

  defp filters_changed?(socket, filters) do
    filters.search != (socket.assigns[:search] || "") or
      filters.ip != (socket.assigns[:ip_filter] || "") or
      Enum.sort(filters.lifecycle) != Enum.sort(socket.assigns[:lifecycle_filter] || []) or
      Enum.sort(filters.project_id) != Enum.sort(socket.assigns[:project_filter] || []) or
      Enum.sort(filters.org_id) != Enum.sort(socket.assigns[:org_filter] || []) or
      Enum.sort(filters.brand_id) != Enum.sort(socket.assigns[:brand_filter] || [])
  end

  defp parse_filters(params) do
    %{
      search: Map.get(params, "search", ""),
      ip: Map.get(params, "ip", ""),
      lifecycle: params |> Map.get("lifecycle", "") |> parse_lifecycle_list(),
      project_id: params |> Map.get("project_id", "") |> parse_int_list(),
      org_id: params |> Map.get("organization_id", "") |> parse_int_list(),
      brand_id: params |> Map.get("brand_id", "") |> parse_int_list(),
      page: params |> Map.get("page", "1") |> Integer.parse() |> elem(0)
    }
  end

  defp parse_lifecycle_list(""), do: []
  defp parse_lifecycle_list(nil), do: []

  defp parse_lifecycle_list(s) do
    s
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_atom/1)
  end

  defp parse_int_list(""), do: []
  defp parse_int_list(nil), do: []

  defp parse_int_list(s) do
    s
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_int/1)
    |> Enum.reject(&is_nil/1)
  end

  defp apply_metadata_preload(domains, expanded) do
    if MapSet.size(expanded) > 0 do
      Enum.map(domains, fn d ->
        if MapSet.member?(expanded, "#{d.id}") do
          Domains.preload_subdomain_metadata(d)
        else
          d
        end
      end)
    else
      domains
    end
  end

  defp execute_bulk_delete(socket) do
    ids = socket.assigns.selected_ids |> MapSet.to_list() |> Enum.map(&String.to_integer/1)
    {:ok, count} = Domains.bulk_delete(ids)

    params = build_params(socket)

    {:noreply,
     socket
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:include_subdomains, false)
     |> assign(:bulk_action, nil)
     |> assign(:bulk_lifecycle_menu_open, false)
     |> assign(:scanning_ids, MapSet.new())
     |> assign(:ip_filter, "")
     |> assign(:export_include_subs, false)
     |> put_flash(:info, "Deleted #{count} domain#{if count != 1, do: "s", else: ""}")
     |> push_patch(to: ~p"/domains?#{params}")}
  end

  defp execute_bulk_scan(socket) do
    ids = socket.assigns.selected_ids |> MapSet.to_list() |> Enum.map(&String.to_integer/1)
    include_subdomains = socket.assigns.include_subdomains

    execute_scan_on_ids(socket, ids, include_subdomains)
  end

  defp execute_scan_on_ids(socket, ids, include_subdomains) do
    scan_targets = get_scan_targets(ids, include_subdomains)
    liveview_pid = self()

    # IDs to show as "scanning" in UI
    target_ids = Enum.map(scan_targets, &to_string(&1.id))
    new_scanning = MapSet.union(socket.assigns.scanning_ids, MapSet.new(target_ids))

    Task.start(fn ->
      Task.async_stream(
        scan_targets,
        fn domain ->
          Scans.run_dnsx_scan(domain.id)
          Scans.run_httpx_scan(domain.id)
          Scans.run_rdap_scan(domain.id)
          Scans.run_subdomain_scan(domain.id)
          send(liveview_pid, {:quick_scan_done, domain.id})
        end,
        max_concurrency: 10,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()
    end)

    count = length(scan_targets)
    params = build_params(socket)

    {:noreply,
     socket
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:include_subdomains, false)
     |> assign(:bulk_action, nil)
     |> assign(:bulk_lifecycle_menu_open, false)
     |> assign(:scanning_ids, new_scanning)
     |> put_flash(:info, "Scan started for #{count} domain#{if count != 1, do: "s", else: ""}")
     |> push_patch(to: ~p"/domains?#{params}")}
  end

  defp get_scan_targets(ids, true) do
    domains = Enum.map(ids, &Domains.get_domain_with_preloads!/1)
    domains ++ Enum.flat_map(domains, & &1.subdomains)
  end

  defp get_scan_targets(ids, false) do
    Enum.map(ids, &Domains.get_domain!/1)
  end

  defp execute_bulk_lifecycle(socket, state) do
    ids = socket.assigns.selected_ids |> MapSet.to_list() |> Enum.map(&String.to_integer/1)

    Enum.each(ids, fn id ->
      domain = Domains.get_domain!(id)
      Domains.update_domain(domain, %{lifecycle_state: state})
    end)

    count = length(ids)
    {_state, label, _color} = Enum.find(lifecycle_options(), fn {s, _, _} -> s == state end)
    params = build_params(socket)

    {:noreply,
     socket
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:include_subdomains, false)
     |> assign(:bulk_action, nil)
     |> assign(:bulk_lifecycle_menu_open, false)
     |> assign(:scanning_ids, MapSet.new())
     |> assign(:ip_filter, "")
     |> assign(:export_include_subs, false)
     |> put_flash(:info, "Set #{count} domain#{if count != 1, do: "s", else: ""} to #{label}")
     |> push_patch(to: ~p"/domains?#{params}")}
  end


  defp build_params(socket, overrides \\ []) do
    search = Keyword.get(overrides, :search, socket.assigns[:search] || "")
    ip = Keyword.get(overrides, :ip, socket.assigns[:ip_filter] || "")
    page = Keyword.get(overrides, :page, socket.assigns[:page] || 1)
    project_ids = Keyword.get(overrides, :project_id, socket.assigns[:project_filter] || [])
    org_ids = Keyword.get(overrides, :organization_id, socket.assigns[:org_filter] || [])
    brand_ids = Keyword.get(overrides, :brand_id, socket.assigns[:brand_filter] || [])
    lifecycles = Keyword.get(overrides, :lifecycle, socket.assigns[:lifecycle_filter] || [])

    [
      search: search,
      ip: ip,
      lifecycle: lifecycles |> Enum.map(&to_string/1) |> Enum.join(","),
      project_id: project_ids |> Enum.map(&to_string/1) |> Enum.join(","),
      organization_id: org_ids |> Enum.map(&to_string/1) |> Enum.join(","),
      brand_id: brand_ids |> Enum.map(&to_string/1) |> Enum.join(","),
      page: page
    ]
    |> Enum.reject(fn {_, v} -> v == "" or v == 1 end)
  end

  defp parse_int(""), do: nil
  defp parse_int(nil), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(n) when is_integer(n), do: n

  defp editor?(nil), do: false

  defp editor?(scope) do
    role_rank = %{viewer: 0, editor: 1, admin: 2}
    user = scope.user
    user && Map.get(role_rank, user.role, 0) >= 1
  end

  defp lifecycle_color(:priority), do: "bg-teal-600"
  defp lifecycle_color(:active), do: "bg-green-500"
  defp lifecycle_color(:placeholder), do: "bg-violet-500"
  defp lifecycle_color(:under_review), do: "bg-yellow-500"
  defp lifecycle_color(:redirect), do: "bg-cyan-500"
  defp lifecycle_color(:insecure), do: "bg-amber-600"
  defp lifecycle_color(:error), do: "bg-red-500"
  defp lifecycle_color(:deprecated), do: "bg-orange-500"
  defp lifecycle_color(:decommissioned), do: "bg-red-500"
  defp lifecycle_color(:abandoned), do: "bg-neutral-400"
  defp lifecycle_color(_), do: "bg-neutral-400"

  defp lifecycle_options do
    [
      {:priority, "Priority", "bg-teal-600"},
      {:active, "Active", "bg-green-500"},
      {:under_review, "Under review", "bg-yellow-500"},
      {:placeholder, "Placeholder", "bg-violet-500"},
      {:insecure, "Insecure HTTP", "bg-amber-600"},
      {:redirect, "Redirect", "bg-cyan-500"},
      {:deprecated, "Deprecated", "bg-orange-400"},
      {:decommissioned, "Decommissioned", "bg-red-500"},
      {:error, "Error", "bg-red-500"},
      {:abandoned, "Abandoned", "bg-neutral-400"}
    ]
  end

  # Returns true if final_url points to a different host than the domain name.
  def external_redirect?(domain_name, final_url) when is_binary(final_url) do
    final_host =
      final_url
      |> URI.parse()
      |> Map.get(:host)
      |> Kernel.||("")
      |> String.replace_leading("www.", "")

    own_host = String.replace_leading(domain_name, "www.", "")
    final_host != "" && final_host != own_host
  end

  def external_redirect?(_domain_name, _final_url), do: false

  defp page_range(_current, total) when total <= 7 do
    Enum.to_list(1..total)
  end

  defp page_range(current, total) do
    cond do
      current <= 4 ->
        Enum.to_list(1..5) ++ [:ellipsis, total]

      current >= total - 3 ->
        [1, :ellipsis] ++ Enum.to_list((total - 4)..total)

      true ->
        [1, :ellipsis] ++ Enum.to_list((current - 1)..(current + 1)) ++ [:ellipsis, total]
    end
  end

  defp toggle_mapset(set, member) do
    if MapSet.member?(set, member), do: MapSet.delete(set, member), else: MapSet.put(set, member)
  end

  end
