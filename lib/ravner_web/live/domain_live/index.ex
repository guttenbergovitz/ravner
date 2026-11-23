defmodule RavnerWeb.DomainLive.Index do
  @moduledoc """
  LiveView for the domain listing page.
  Supports filtering, pagination, selection mode, and bulk operations.
  """
  use RavnerWeb, :live_view

  import RavnerWeb.DomainComponents,
    only: [
      technical_status_indicator: 1,
      technical_status_options: 0,
      checkbox_indicator: 1,
      selection_bar: 1
    ]

  import RavnerWeb.DomainLive.IndexModals
  import RavnerWeb.DomainLive.IndexRow
  import RavnerWeb.DomainLive.IndexSidebar

  alias Ravner.A11y
  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Inventory
  alias Ravner.Lighthouse
  alias RavnerWeb.DomainLive.SelectionCoordinator
  require Logger

  @technical_status_states %{
    "unknown" => :unknown,
    "reachable" => :reachable,
    "redirect" => :redirect,
    "insecure" => :insecure,
    "error" => :error
  }

  @lifecycle_states %{
    "priority" => :priority,
    "active" => :active,
    "under_review" => :under_review,
    "placeholder" => :placeholder,
    "deprecated" => :deprecated,
    "decommissioned" => :decommissioned,
    "abandoned" => :abandoned
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      RavnerWeb.Endpoint.subscribe("scans")

      Phoenix.PubSub.subscribe(
        Ravner.PubSub,
        "bulk_scans:user:#{socket.assigns.current_scope.user.id}"
      )
    end

    {:ok,
     socket
     |> assign_initial_state()
     |> assign(:brands, Inventory.list_brands(scope: socket.assigns[:current_scope]))
     |> assign(:orgs, Inventory.list_organizations(scope: socket.assigns[:current_scope]))
     |> assign(:projects, Inventory.list_projects(scope: socket.assigns[:current_scope]))
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

    if socket.assigns.live_action in [:new, :import] and
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

  @impl true
  def handle_event("suggest", %{"search" => query}, socket) do
    include_subdomains = socket.assigns[:include_subdomains] || false

    suggestions =
      Domains.suggest_domains(query, 5,
        include_subdomains: include_subdomains,
        scope: socket.assigns[:current_scope]
      )

    {:noreply, assign(socket, :suggestions, suggestions)}
  end

  @impl true
  def handle_event("suggest", _params, socket) do
    {:noreply, assign(socket, :suggestions, [])}
  end

  @impl true
  def handle_event("dismiss_suggestions", _params, socket) do
    {:noreply, assign(socket, :suggestions, [])}
  end

  @impl true
  def handle_event("clear_search", _params, socket) do
    params = build_params(socket, search: "", page: 1)
    {:noreply, socket |> assign(:suggestions, []) |> push_patch(to: ~p"/domains?#{params}")}
  end

  @impl true
  def handle_event("select_suggestion", %{"name" => name}, socket) do
    params = build_params(socket, search: name, page: 1)
    {:noreply, socket |> assign(:suggestions, []) |> push_patch(to: ~p"/domains?#{params}")}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/domains")}
  end

  @impl true
  def handle_event("filter_ip", %{"ip" => ip}, socket) do
    params = build_params(socket, ip: ip, page: 1)
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  @impl true
  def handle_event("clear_ip", _params, socket) do
    params = build_params(socket, ip: "")
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  @impl true
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
          "technology" -> [technology: new_val]
        end

      params = build_params(socket, overrides ++ [page: 1])
      {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
    else
      :error -> {:noreply, put_flash(socket, :error, "Invalid filter value.")}
    end
  end

  @impl true
  def handle_event("clear_filter", %{"type" => type}, socket) do
    overrides =
      case type do
        "lifecycle" -> [lifecycle: []]
        "technical_status" -> [technical_status: []]
        "brand" -> [brand_id: []]
        "org" -> [organization_id: []]
        "project" -> [project_id: []]
        "technology" -> [technology: []]
      end

    params = build_params(socket, overrides ++ [page: 1])
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  @impl true
  def handle_event("toggle_empty_facets", _params, socket) do
    {:noreply, assign(socket, :show_empty_facets, !socket.assigns.show_empty_facets)}
  end

  @impl true
  def handle_event("toggle_filter_subdomains", _params, socket) do
    params = build_params(socket, include_subdomains: !socket.assigns.include_subdomains, page: 1)

    {:noreply,
     socket
     |> assign(:include_subdomains, !socket.assigns.include_subdomains)
     |> push_patch(to: ~p"/domains?#{params}")}
  end

  @impl true
  def handle_event("toggle_monitored_only", _params, socket) do
    params = build_params(socket, monitored_only: !socket.assigns.monitored_only, page: 1)

    {:noreply,
     socket
     |> assign(:monitored_only, !socket.assigns.monitored_only)
     |> push_patch(to: ~p"/domains?#{params}")}
  end

  @impl true
  def handle_event("toggle_show_archived", _params, socket) do
    params = build_params(socket, show_archived: !socket.assigns.show_archived, page: 1)

    {:noreply,
     socket
     |> assign(:show_archived, !socket.assigns.show_archived)
     |> push_patch(to: ~p"/domains?#{params}")}
  end

  @impl true
  def handle_event("toggle_hide_placeholders", _params, socket) do
    params = build_params(socket, hide_placeholders: !socket.assigns.hide_placeholders, page: 1)

    {:noreply,
     socket
     |> assign(:hide_placeholders, !socket.assigns.hide_placeholders)
     |> push_patch(to: ~p"/domains?#{params}")}
  end

  @impl true
  def handle_event("toggle_facet_group", %{"group" => group}, socket) do
    new_expanded = toggle_mapset(socket.assigns.expanded_facets, group)
    {:noreply, assign(socket, :expanded_facets, new_expanded)}
  end

  @impl true
  def handle_event("paginate", %{"page" => page_str}, socket) do
    page = page_str |> Integer.parse() |> elem(0)
    params = build_params(socket, page: page)
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  @impl true
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

    socket =
      socket
      |> assign(:expanded_domains, new_expanded)
      |> restream_domains()

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_export_subs", _params, socket) do
    SelectionCoordinator.toggle_export_subs(socket)
  end

  @impl true
  def handle_event("enter_selection_mode", _params, socket) do
    SelectionCoordinator.enter_selection_mode(socket)
  end

  @impl true
  def handle_event("exit_selection_mode", _params, socket) do
    {:noreply, socket} = SelectionCoordinator.exit_selection_mode(socket)
    {:noreply, restream_domains(socket)}
  end

  @impl true
  def handle_event("toggle_select", %{"id" => id}, socket) do
    {:noreply, socket} = SelectionCoordinator.toggle_select(socket, id)
    {:noreply, restream_domains(socket)}
  end

  @impl true
  def handle_event("select_all_matching", _params, socket) do
    {:noreply, socket} = SelectionCoordinator.select_all_matching(socket, &build_params/1)
    {:noreply, restream_domains(socket)}
  end

  @impl true
  def handle_event("select_visible", _params, socket) do
    {:noreply, socket} = SelectionCoordinator.select_visible(socket)
    {:noreply, restream_domains(socket)}
  end

  @impl true
  def handle_event("toggle_include_subdomains", _params, socket) do
    SelectionCoordinator.toggle_include_subdomains(socket)
  end

  @impl true
  def handle_event("open_lifecycle_menu", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:lifecycle_menu_open, id) |> restream_domains()}
  end

  @impl true
  def handle_event("close_lifecycle_menu", _params, socket) do
    {:noreply, socket |> assign(:lifecycle_menu_open, nil) |> restream_domains()}
  end

  @impl true
  def handle_event("set_lifecycle", %{"id" => id, "state" => state}, socket) do
    domain = Domains.get_domain!(id)
    actor = socket.assigns.current_scope.user

    case Domains.set_domain_lifecycle(domain, state, actor: actor) do
      {:ok, updated_domain} ->
        updated_domains = replace_domain(socket.assigns.domains, updated_domain)

        {:noreply,
         socket
         |> assign(:lifecycle_menu_open, nil)
         |> assign_domains(updated_domains)
         |> put_flash(:info, "Lifecycle updated")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update lifecycle")}
    end
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, socket} = SelectionCoordinator.clear_selection(socket)
    {:noreply, restream_domains(socket)}
  end

  @impl true
  def handle_event("toggle_bulk_actions_menu", _params, socket) do
    SelectionCoordinator.toggle_bulk_actions_menu(socket)
  end

  @impl true
  def handle_event("close_bulk_actions_menu", _params, socket) do
    SelectionCoordinator.close_bulk_actions_menu(socket)
  end

  @impl true
  def handle_event("toggle_more_menu", _params, socket) do
    {:noreply, assign(socket, :more_menu_open, !socket.assigns.more_menu_open)}
  end

  @impl true
  def handle_event("close_more_menu", _params, socket) do
    {:noreply, assign(socket, :more_menu_open, false)}
  end

  @impl true
  def handle_event("bulk_action_confirm", params, socket) do
    SelectionCoordinator.bulk_action_confirm(socket, params)
  end

  @impl true
  def handle_event("bulk_action_cancel", _params, socket) do
    SelectionCoordinator.bulk_action_cancel(socket)
  end

  @impl true
  def handle_event("bulk_action_execute", _params, socket) do
    {:noreply, socket} = SelectionCoordinator.bulk_action_execute(socket, &refresh_after_bulk/1)
    {:noreply, restream_domains(socket)}
  end

  @impl true
  def handle_event("quick_scan", %{"id" => id}, socket) do
    {:noreply, socket} = SelectionCoordinator.quick_scan(socket, id)
    {:noreply, restream_domains(socket)}
  end

  @impl true
  def handle_event("scan_visible", _, socket) do
    {:noreply, socket} = SelectionCoordinator.scan_visible(socket, &refresh_after_bulk/1)
    {:noreply, restream_domains(socket)}
  end

  @impl true
  def handle_event("ip_copied", %{"ip" => ip}, socket) do
    {:noreply, put_flash(socket, :info, "Copied IP: #{ip}")}
  end

  @impl true
  def handle_event("validate", %{"domain" => domain_params}, socket) do
    changeset =
      socket.assigns.domain
      |> Domains.change_domain(domain_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
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

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create domain: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("import", %{"import" => %{"domains" => domains}}, socket) do
    results = Domains.bulk_import(domains, actor: socket.assigns.current_scope.user)

    {:noreply,
     socket
     |> assign(:import_results, results)
     |> assign(:importing, false)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/domains")}
  end

  @impl true
  def handle_info({:quick_scan_done, domain_id}, socket) do
    SelectionCoordinator.handle_scan_done(socket, domain_id, fn s ->
      push_patch(s, to: ~p"/domains?#{build_params(s)}")
    end)
  end

  @impl true
  def handle_info({:security_scan_done, domain_id}, socket) do
    SelectionCoordinator.handle_scan_done(socket, domain_id, fn s ->
      push_patch(s, to: ~p"/domains?#{build_params(s)}")
    end)
  end

  @impl true
  def handle_info({:bulk_scan_done, domain_id, _scan_type, _status}, socket) do
    SelectionCoordinator.handle_scan_done(socket, domain_id, fn s ->
      push_patch(s, to: ~p"/domains?#{build_params(s)}")
    end)
  end

  defp refresh_after_bulk(socket) do
    push_patch(socket, to: ~p"/domains?#{build_params(socket)}")
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp assign_initial_state(socket) do
    socket
    |> stream_configure(:domains, dom_id: &"domain-#{&1.id}")
    |> stream(:domains, [])
    |> assign(:domains, [])
    |> assign(:domains_empty?, true)
    |> assign(:a11y_violations, %{})
    |> assign(:lighthouse_scores, %{})
    |> assign(:total, 0)
    |> assign(:page, 1)
    |> assign(:total_pages, 1)
    |> assign(:search, "")
    |> assign(:expanded_domains, MapSet.new())
    |> assign(:lifecycle_menu_open, nil)
    |> assign(:form, nil)
    |> assign(:import_results, nil)
    |> assign(:importing, false)
    |> assign(:suggestions, [])
    |> assign(:selection_mode, false)
    |> assign(:selected_ids, MapSet.new())
    |> assign(:include_subdomains, false)
    |> assign(:monitored_only, false)
    |> assign(:bulk_include_subdomains, false)
    |> assign(:bulk_action, nil)
    |> assign(:bulk_actions_menu_open, false)
    |> assign(:more_menu_open, false)
    |> assign(:scanning_ids, MapSet.new())
    |> assign(:ip_filter, "")
    |> assign(:export_include_subs, false)
    |> assign(:technical_status_filter, [])
    |> assign(:project_filter, [])
    |> assign(:org_filter, [])
    |> assign(:brand_filter, [])
    |> assign(:lifecycle_filter, [])
    |> assign(:technology_filter, [])
    |> assign(:show_archived, false)
    |> assign(:hide_placeholders, false)
    |> assign(:show_empty_facets, false)
    |> assign(
      :expanded_facets,
      MapSet.new(["lifecycle", "technical_status", "brand", "technology"])
    )
    |> assign(:facets, %{
      lifecycle: [],
      technical_status: [],
      brands: [],
      organizations: [],
      projects: [],
      technologies: []
    })
  end

  defp apply_action(socket, :index, params) do
    filters = parse_filters(params)
    filter_list = [scope: socket.assigns[:current_scope]] ++ Map.to_list(filters)
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
    lighthouse_scores = Lighthouse.scores_by_domain_ids(domain_ids)

    socket
    |> assign(:page_title, "Domains")
    |> assign(:domain, nil)
    |> assign(:a11y_violations, a11y_violations)
    |> assign(:lighthouse_scores, lighthouse_scores)
    |> assign(:total, result.total)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:search, filters.search)
    |> assign(:ip_filter, filters.ip)
    |> assign(:include_subdomains, filters.include_subdomains)
    |> assign(:monitored_only, filters.monitored_only)
    |> assign(:show_archived, filters.show_archived)
    |> assign(:hide_placeholders, filters.hide_placeholders)
    |> assign(:technical_status_filter, filters.technical_status)
    |> assign(:lifecycle_filter, filters.lifecycle)
    |> assign(:project_filter, filters.project_id)
    |> assign(:org_filter, filters.org_id)
    |> assign(:brand_filter, filters.brand_id)
    |> assign(:technology_filter, filters.technology)
    |> assign(:facets, facets)
    |> assign_domains(domains)
  end

  defp assign_domains(socket, domains) do
    socket
    |> assign(:domains, domains)
    |> assign(:domains_empty?, domains == [])
    |> stream(:domains, domains, reset: true)
  end

  defp restream_domains(socket) do
    stream(socket, :domains, socket.assigns.domains, reset: true)
  end

  defp maybe_clear_selection(socket, filters) do
    if filters_changed?(socket, filters) do
      socket
      |> assign(:selected_ids, MapSet.new())
      |> restream_domains()
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
      monitored_only: Map.get(params, "monitored_only", "false") == "true",
      show_archived: Map.get(params, "show_archived", "false") == "true",
      hide_placeholders: Map.get(params, "hide_placeholders", "false") == "true",
      technical_status:
        params |> Map.get("technical_status", "") |> parse_technical_status_list(),
      lifecycle: params |> Map.get("lifecycle", "") |> parse_lifecycle_list(),
      project_id: params |> Map.get("project_id", "") |> parse_int_list(),
      org_id: params |> Map.get("organization_id", "") |> parse_int_list(),
      organization_id: params |> Map.get("organization_id", "") |> parse_int_list(),
      brand_id: params |> Map.get("brand_id", "") |> parse_int_list(),
      technology: params |> Map.get("technology", "") |> parse_string_list(),
      page: params |> Map.get("page", "1") |> Integer.parse() |> elem(0)
    }
  end

  defp parse_string_list(""), do: []
  defp parse_string_list(nil), do: []

  defp parse_string_list(s) do
    s
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
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

    monitored =
      Keyword.get(
        overrides,
        :monitored_only,
        Map.get(socket.assigns, :monitored_only, false)
      )

    show_archived =
      Keyword.get(
        overrides,
        :show_archived,
        Map.get(socket.assigns, :show_archived, false)
      )

    hide_placeholders =
      Keyword.get(
        overrides,
        :hide_placeholders,
        Map.get(socket.assigns, :hide_placeholders, false)
      )

    [
      search: search,
      ip: ip,
      include_subdomains: if(subdomains, do: "true", else: ""),
      monitored_only: if(monitored, do: "true", else: ""),
      show_archived: if(show_archived, do: "true", else: ""),
      hide_placeholders: if(hide_placeholders, do: "true", else: ""),
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
      technology:
        Enum.map_join(extract_param.(:technology, :technology_filter), ",", &to_string/1),
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
  defp facet_assign("technology"), do: {:ok, :technology_filter}
  defp facet_assign(_), do: :error

  defp facet_value("lifecycle", id), do: Map.fetch(@lifecycle_states, id)
  defp facet_value("technical_status", id), do: Map.fetch(@technical_status_states, id)
  defp facet_value("technology", id), do: {:ok, id}

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

  # Returns true if final_url points to a different apex domain than the domain name.
  def external_redirect?(domain_name, final_url),
    do: Ravner.Scans.external_redirect?(domain_name, final_url)

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

  defp toggle_mapset(set, item) do
    if MapSet.member?(set, item), do: MapSet.delete(set, item), else: MapSet.put(set, item)
  end
end
