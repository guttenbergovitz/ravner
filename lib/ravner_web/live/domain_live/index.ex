defmodule RavnerWeb.DomainLive.Index do
  @moduledoc """
  LiveView for the domain listing page.
  Supports filtering, pagination, selection mode, and bulk operations.
  """
  use RavnerWeb, :live_view

  import RavnerWeb.DomainComponents,
    only: [
      lifecycle_dot_class: 1,
      lifecycle_dot_class: 2,
      technical_status_indicator: 1,
      technical_status_options: 0
    ]

  alias Ravner.A11y
  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Inventory
  alias Ravner.Scans

  @bulk_actions %{"delete" => :delete, "scan" => :scan}
  @lifecycle_states %{
    "priority" => :priority,
    "active" => :active,
    "under_review" => :under_review,
    "placeholder" => :placeholder,
    "deprecated" => :deprecated,
    "decommissioned" => :decommissioned,
    "abandoned" => :abandoned
  }

  @technical_status_states %{
    "unknown" => :unknown,
    "reachable" => :reachable,
    "redirect" => :redirect,
    "insecure" => :insecure,
    "error" => :error
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: RavnerWeb.Endpoint.subscribe("scans")

    {:ok,
     socket
     |> assign_initial_state()
     |> assign(:brands, Inventory.list_brands())
     |> assign(:orgs, Inventory.list_organizations())
     |> assign(:projects, Inventory.list_projects())
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
    with {:ok, field} <- facet_assign(type),
         {:ok, id_val} <- facet_value(type, id) do
      current_val = socket.assigns[field] || []

      new_val =
        if id_val in current_val do
          List.delete(current_val, id_val)
        else
          [id_val | current_val]
        end

      overrides =
        case type do
          "lifecycle" -> [lifecycle: new_val]
          "technical_status" -> [technical_status: new_val]
          "brand" -> [brand_id: new_val]
          "org" -> [organization_id: new_val]
          "project" -> [project_id: new_val]
        end

      params = build_params(socket, overrides ++ [page: 1])
      {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
    else
      :error -> {:noreply, put_flash(socket, :error, "Invalid filter value.")}
    end
  end

  def handle_event("clear_filter", %{"type" => type}, socket) do
    overrides =
      case type do
        "lifecycle" -> [lifecycle: []]
        "technical_status" -> [technical_status: []]
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

  def handle_event("toggle_filter_subdomains", _params, socket) do
    params = build_params(socket, include_subdomains: !socket.assigns.include_subdomains, page: 1)

    {:noreply,
     socket
     |> assign(:include_subdomains, !socket.assigns.include_subdomains)
     |> push_patch(to: ~p"/domains?#{params}")}
  end

  def handle_event("toggle_facet_group", %{"group" => group}, socket) do
    new_expanded = toggle_mapset(socket.assigns.expanded_facets, group)
    {:noreply, assign(socket, :expanded_facets, new_expanded)}
  end

  def handle_event("paginate", %{"page" => page_str}, socket) do
    page = page_str |> Integer.parse() |> elem(0)
    params = build_params(socket, page: page)
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_domains
    new_expanded = toggle_mapset(expanded, id)

    socket =
      if MapSet.member?(new_expanded, id) do
        domain_id = String.to_integer(id)
        domain = Enum.find(socket.assigns.domains, &(&1.id == domain_id))

        if domain && domain.subdomains != [] do
          updated_domain = Domains.preload_subdomain_metadata(domain)

          updated_domains =
            Enum.map(socket.assigns.domains, fn d ->
              if d.id == domain_id, do: updated_domain, else: d
            end)

          assign(socket, :domains, updated_domains)
        else
          socket
        end
      else
        socket
      end

    {:noreply, assign(socket, :expanded_domains, new_expanded)}
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
     |> assign(:bulk_include_subdomains, false)
     |> assign(:bulk_action, nil)
     |> assign(:bulk_lifecycle_menu_open, false)
     |> assign(:bulk_brand_menu_open, false)
     |> assign(:bulk_org_menu_open, false)
     |> assign(:bulk_project_menu_open, false)
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

    ids =
      params
      |> Map.to_list()
      |> Domains.ids_matching_filters()
      |> Enum.map(&to_string/1)

    {:noreply, assign(socket, :selected_ids, MapSet.new(ids))}
  end

  def handle_event("select_visible", _params, socket) do
    ids = Enum.map(socket.assigns.domains, &to_string(&1.id))
    {:noreply, assign(socket, :selected_ids, MapSet.new(ids))}
  end

  def handle_event("toggle_include_subdomains", _params, socket) do
    {:noreply, assign(socket, :bulk_include_subdomains, !socket.assigns.bulk_include_subdomains)}
  end

  def handle_event("open_lifecycle_menu", %{"id" => id}, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, id)}
  end

  def handle_event("close_lifecycle_menu", _params, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, nil)}
  end

  def handle_event("set_lifecycle", %{"id" => id, "state" => state}, socket) do
    domain = Domains.get_domain!(id)
    actor = socket.assigns.current_scope.user

    case Domains.set_domain_lifecycle(domain, state, actor: actor) do
      {:ok, updated_domain} ->
        {:noreply,
         socket
         |> assign(:domains, replace_domain(socket.assigns.domains, updated_domain))
         |> assign(:lifecycle_menu_open, nil)
         |> put_flash(:info, "Lifecycle updated")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update lifecycle")}
    end
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new())}
  end

  def handle_event("toggle_bulk_actions_menu", _params, socket) do
    {:noreply, assign(socket, :bulk_actions_menu_open, !socket.assigns.bulk_actions_menu_open)}
  end

  def handle_event("close_bulk_actions_menu", _params, socket) do
    {:noreply, assign(socket, :bulk_actions_menu_open, false)}
  end

  def handle_event("bulk_action_confirm", %{"action" => action}, socket) do
    case Map.fetch(@bulk_actions, action) do
      {:ok, bulk_action} ->
        {:noreply,
         socket
         |> assign(:bulk_actions_menu_open, false)
         |> assign(:bulk_action, bulk_action)}

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid bulk action.")}
    end
  end

  def handle_event("bulk_action_confirm", %{"lifecycle" => state}, socket) do
    case Map.fetch(@lifecycle_states, state) do
      {:ok, lifecycle} ->
        {:noreply,
         socket
         |> assign(:bulk_actions_menu_open, false)
         |> assign(:bulk_action, {:lifecycle, lifecycle})}

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid lifecycle state.")}
    end
  end

  def handle_event("bulk_action_confirm", %{"brand_id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:bulk_actions_menu_open, false)
     |> assign(:bulk_action, {:brand, String.to_integer(id)})}
  end

  def handle_event("bulk_action_confirm", %{"org_id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:bulk_actions_menu_open, false)
     |> assign(:bulk_action, {:org, String.to_integer(id)})}
  end

  def handle_event("bulk_action_confirm", %{"project_id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:bulk_actions_menu_open, false)
     |> assign(:bulk_action, {:project, String.to_integer(id)})}
  end

  def handle_event("bulk_action_cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(:bulk_action, nil)
     |> assign(:bulk_actions_menu_open, false)}
  end

  def handle_event("bulk_action_execute", _params, socket) do
    socket = assign(socket, :bulk_actions_menu_open, false)

    case socket.assigns.bulk_action do
      :delete -> execute_bulk_delete(socket)
      :scan -> execute_bulk_scan(socket)
      {:lifecycle, state} -> execute_bulk_lifecycle(socket, state)
      {type, id} when type in [:brand, :org, :project] -> execute_bulk_assign(socket, type, id)
    end
  end

  def handle_event("quick_scan", %{"id" => id}, socket) do
    domain_id = String.to_integer(id)
    liveview_pid = self()
    user_id = socket.assigns.current_scope.user.id

    start_background_scan(user_id, fn ->
      Scans.run_quick_scan(domain_id)
      send(liveview_pid, {:quick_scan_done, domain_id})
    end)

    {:noreply, assign(socket, :scanning_ids, MapSet.put(socket.assigns.scanning_ids, id))}
  end

  def handle_event("scan_visible", _, socket) do
    ids = socket.assigns.domains |> Enum.map(& &1.id)
    include_subdomains = socket.assigns.bulk_include_subdomains

    execute_scan_on_ids(socket, ids, include_subdomains)
  end

  def handle_event("ip_copied", %{"ip" => ip}, socket) do
    {:noreply, put_flash(socket, :info, "Copied IP: #{ip}")}
  end

  def handle_event("validate", %{"domain" => domain_params}, socket) do
    changeset =
      socket.assigns.domain
      |> Domains.change_domain(domain_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"domain" => domain_params}, socket) do
    actor = socket.assigns.current_scope.user

    case Domains.create_domain(domain_params, actor: actor) do
      {:ok, _domain} ->
        {:noreply,
         socket
         |> put_flash(:info, "Domain created successfully")
         |> push_patch(to: ~p"/domains")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("import", %{"import" => %{"domains" => domains}}, socket) do
    results = Domains.bulk_import(domains, actor: socket.assigns.current_scope.user)

    {:noreply,
     socket
     |> assign(:import_results, results)
     |> assign(:importing, false)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/domains")}
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
    |> assign(:domains, [])
    |> assign(:a11y_violations, %{})
    |> assign(:total, 0)
    |> assign(:page, 1)
    |> assign(:total_pages, 1)
    |> assign(:search, "")
    |> assign(:expanded_domains, MapSet.new())
    |> assign(:lifecycle_menu_open, nil)
    |> assign(:importing, false)
    |> assign(:suggestions, [])
    |> assign(:selection_mode, false)
    |> assign(:selected_ids, MapSet.new())
    |> assign(:include_subdomains, false)
    |> assign(:bulk_include_subdomains, false)
    |> assign(:bulk_action, nil)
    |> assign(:bulk_actions_menu_open, false)
    |> assign(:scanning_ids, MapSet.new())
    |> assign(:ip_filter, "")
    |> assign(:export_include_subs, false)
    |> assign(:technical_status_filter, [])
    |> assign(:project_filter, [])
    |> assign(:org_filter, [])
    |> assign(:brand_filter, [])
    |> assign(:lifecycle_filter, [])
    |> assign(:show_empty_facets, false)
    |> assign(:expanded_facets, MapSet.new(["lifecycle", "technical_status", "brand"]))
    |> assign(:facets, %{
      lifecycle: [],
      technical_status: [],
      brands: [],
      organizations: [],
      projects: []
    })
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
    domain_ids = Enum.map(domains, & &1.id)
    a11y_violations = A11y.violations_by_domain_ids(domain_ids)

    socket
    |> assign(:page_title, "Domains")
    |> assign(:domain, nil)
    |> assign(:domains, domains)
    |> assign(:a11y_violations, a11y_violations)
    |> assign(:total, result.total)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:search, filters.search)
    |> assign(:ip_filter, filters.ip)
    |> assign(:include_subdomains, filters.include_subdomains)
    |> assign(:technical_status_filter, filters.technical_status)
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
    assigns = socket.assigns

    current = %{
      search: Map.get(assigns, :search, ""),
      ip: Map.get(assigns, :ip_filter, ""),
      include_subdomains: Map.get(assigns, :include_subdomains, false),
      technical_status: Enum.sort(Map.get(assigns, :technical_status_filter, [])),
      lifecycle: Enum.sort(Map.get(assigns, :lifecycle_filter, [])),
      project_id: Enum.sort(Map.get(assigns, :project_filter, [])),
      org_id: Enum.sort(Map.get(assigns, :org_filter, [])),
      brand_id: Enum.sort(Map.get(assigns, :brand_filter, []))
    }

    new_filters = %{
      search: filters.search,
      ip: filters.ip,
      include_subdomains: filters.include_subdomains,
      technical_status: Enum.sort(filters.technical_status),
      lifecycle: Enum.sort(filters.lifecycle),
      project_id: Enum.sort(filters.project_id),
      org_id: Enum.sort(filters.org_id),
      brand_id: Enum.sort(filters.brand_id)
    }

    current != new_filters
  end

  defp parse_filters(params) do
    %{
      search: Map.get(params, "search", ""),
      ip: Map.get(params, "ip", ""),
      include_subdomains: Map.get(params, "include_subdomains", "false") == "true",
      technical_status:
        params |> Map.get("technical_status", "") |> parse_technical_status_list(),
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
    |> Enum.map(&Map.get(@lifecycle_states, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_technical_status_list(""), do: []
  defp parse_technical_status_list(nil), do: []

  defp parse_technical_status_list(s) do
    s
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Map.get(@technical_status_states, &1))
    |> Enum.reject(&is_nil/1)
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
      {to_load, _rest} =
        Enum.split_with(domains, fn d -> MapSet.member?(expanded, "#{d.id}") end)

      loaded_map =
        to_load
        |> Domains.preload_subdomain_metadata()
        |> Map.new(&{&1.id, &1})

      Enum.map(domains, fn d -> Map.get(loaded_map, d.id, d) end)
    else
      domains
    end
  end

  defp replace_domain(domains, updated_domain) do
    Enum.map(domains, fn domain ->
      if domain.id == updated_domain.id do
        merge_listing_associations(domain, updated_domain)
      else
        replace_subdomain(domain, updated_domain)
      end
    end)
  end

  defp replace_subdomain(%{subdomains: subdomains} = domain, updated_domain)
       when is_list(subdomains) do
    %{domain | subdomains: replace_domain(subdomains, updated_domain)}
  end

  defp replace_subdomain(domain, _updated_domain), do: domain

  defp merge_listing_associations(current_domain, updated_domain) do
    %{
      updated_domain
      | parent_domain: current_domain.parent_domain,
        subdomains: current_domain.subdomains,
        domain_tags: current_domain.domain_tags,
        domain_metadata: current_domain.domain_metadata,
        project: current_domain.project,
        brand: current_domain.brand,
        organization: current_domain.organization
    }
  end

  defp execute_bulk_delete(socket) do
    ids = socket.assigns.selected_ids |> MapSet.to_list() |> Enum.map(&String.to_integer/1)
    {:ok, count} = Domains.bulk_delete(ids)

    params = build_params(socket)

    {:noreply,
     socket
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:bulk_include_subdomains, false)
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
    include_subdomains = socket.assigns.bulk_include_subdomains

    execute_scan_on_ids(socket, ids, include_subdomains)
  end

  defp execute_scan_on_ids(socket, ids, include_subdomains) do
    scan_targets = get_scan_targets(ids, include_subdomains)
    liveview_pid = self()
    user_id = socket.assigns.current_scope.user.id

    # IDs to show as "scanning" in UI
    target_ids = Enum.map(scan_targets, &to_string(&1.id))
    new_scanning = MapSet.union(socket.assigns.scanning_ids, MapSet.new(target_ids))

    start_background_scan(user_id, fn ->
      Task.async_stream(
        scan_targets,
        fn domain ->
          Ravner.ActivityLog.set_user(user_id)
          Scans.run_quick_scan(domain.id)
          send(liveview_pid, {:quick_scan_done, domain.id})
        end,
        max_concurrency: Scans.scan_max_concurrency(),
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
     |> assign(:bulk_include_subdomains, false)
     |> assign(:bulk_action, nil)
     |> assign(:bulk_lifecycle_menu_open, false)
     |> assign(:scanning_ids, new_scanning)
     |> put_flash(:info, "Scan started for #{count} domain#{if count != 1, do: "s", else: ""}")
     |> push_patch(to: ~p"/domains?#{params}")}
  end

  defp execute_bulk_assign(socket, type, target_id) do
    ids = socket.assigns.selected_ids |> MapSet.to_list() |> Enum.map(&String.to_integer/1)

    {:ok, count} =
      Domains.bulk_assign(ids, type, target_id, actor: socket.assigns.current_scope.user)

    params = build_params(socket)

    {:noreply,
     socket
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:bulk_action, nil)
     |> put_flash(:info, "Assigned #{count} domain#{if count != 1, do: "s", else: ""} to #{type}")
     |> push_patch(to: ~p"/domains?#{params}")}
  end

  defp get_scan_targets(ids, true) do
    domains = Domains.list_domains_with_subdomains(ids)
    domains ++ Enum.flat_map(domains, & &1.subdomains)
  end

  defp get_scan_targets(ids, false) do
    Domains.list_domains_by_ids(ids)
  end

  defp execute_bulk_lifecycle(socket, state) do
    ids = socket.assigns.selected_ids |> MapSet.to_list() |> Enum.map(&String.to_integer/1)

    {:ok, count} =
      Domains.bulk_set_lifecycle(ids, state, actor: socket.assigns.current_scope.user)

    {_state, label, _color} = Enum.find(lifecycle_options(), fn {s, _, _} -> s == state end)
    params = build_params(socket)

    {:noreply,
     socket
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:bulk_include_subdomains, false)
     |> assign(:bulk_action, nil)
     |> assign(:bulk_lifecycle_menu_open, false)
     |> assign(:scanning_ids, MapSet.new())
     |> assign(:ip_filter, "")
     |> assign(:export_include_subs, false)
     |> put_flash(:info, "Set #{count} domain#{if count != 1, do: "s", else: ""} to #{label}")
     |> push_patch(to: ~p"/domains?#{params}")}
  end

  defp build_params(socket, overrides \\ []) do
    extract_param = fn key, socket_key ->
      Keyword.get(overrides, key, Map.get(socket.assigns, socket_key, []))
    end

    search = Keyword.get(overrides, :search, Map.get(socket.assigns, :search, ""))
    ip = Keyword.get(overrides, :ip, Map.get(socket.assigns, :ip_filter, ""))
    page = Keyword.get(overrides, :page, Map.get(socket.assigns, :page, 1))

    subdomains =
      Keyword.get(
        overrides,
        :include_subdomains,
        Map.get(socket.assigns, :include_subdomains, false)
      )

    [
      search: search,
      ip: ip,
      include_subdomains: if(subdomains, do: "true", else: ""),
      lifecycle: Enum.map_join(extract_param.(:lifecycle, :lifecycle_filter), ",", &to_string/1),
      technical_status:
        Enum.map_join(
          extract_param.(:technical_status, :technical_status_filter),
          ",",
          &to_string/1
        ),
      project_id: Enum.map_join(extract_param.(:project_id, :project_filter), ",", &to_string/1),
      organization_id:
        Enum.map_join(extract_param.(:organization_id, :org_filter), ",", &to_string/1),
      brand_id: Enum.map_join(extract_param.(:brand_id, :brand_filter), ",", &to_string/1),
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

  defp facet_assign("lifecycle"), do: {:ok, :lifecycle_filter}
  defp facet_assign("brand"), do: {:ok, :brand_filter}
  defp facet_assign("org"), do: {:ok, :org_filter}
  defp facet_assign("project"), do: {:ok, :project_filter}
  defp facet_assign("technical_status"), do: {:ok, :technical_status_filter}
  defp facet_assign(_), do: :error

  defp facet_value("lifecycle", id), do: Map.fetch(@lifecycle_states, id)
  defp facet_value("technical_status", id), do: Map.fetch(@technical_status_states, id)

  defp facet_value(_type, id) do
    case Integer.parse(id) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp editor?(nil), do: false

  defp editor?(scope) do
    role_rank = %{viewer: 0, editor: 1, admin: 2}
    user = scope.user
    user && Map.get(role_rank, user.role, 0) >= 1
  end

  defp lifecycle_options do
    [
      {:priority, "Priority", "bg-teal-600"},
      {:active, "Active", "bg-green-500"},
      {:under_review, "Under review", "bg-yellow-500"},
      {:placeholder, "Placeholder", "bg-violet-500"},
      {:deprecated, "Deprecated", "bg-orange-400"},
      {:decommissioned, "Decommissioned", "bg-red-500"},
      {:abandoned, "Abandoned", "bg-neutral-400"}
    ]
  end

  # Returns true if final_url points to a different apex domain than the domain name.
  def external_redirect?(domain_name, final_url),
    do: Ravner.Scans.external_redirect?(domain_name, final_url)

  defp open_url(domain, nil), do: preferred_domain_url(domain, nil)
  defp open_url(domain, metadata), do: preferred_domain_url(domain, metadata.final_url)

  defp preferred_domain_url(_domain, url) when is_binary(url) and url != "", do: url

  defp preferred_domain_url(%{url: url}, _fallback) when is_binary(url) and url != "" do
    normalize_url(url)
  end

  defp preferred_domain_url(%{name: name}, _fallback), do: "https://#{name}"

  defp normalize_url(url) do
    if String.starts_with?(url, ["http://", "https://"]), do: url, else: "https://#{url}"
  end

  defp url_host(url) when is_binary(url) do
    case URI.parse(url) do
      %{host: host} when is_binary(host) -> String.replace_leading(host, "www.", "")
      _ -> url
    end
  end

  defp landing_label(domain, nil), do: domain.name

  defp landing_label(domain, metadata),
    do: metadata.final_url |> Kernel.||(open_url(domain, metadata)) |> url_host()

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

  defp start_background_scan(user_id, fun) when is_function(fun, 0) do
    Task.Supervisor.start_child(Ravner.ScanTaskSupervisor, fn ->
      if user_id, do: Ravner.ActivityLog.set_user(user_id)
      fun.()
    end)
  end
end
