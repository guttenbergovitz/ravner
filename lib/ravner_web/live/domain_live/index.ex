defmodule RavnerWeb.DomainLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Scans

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:expanded_domains, MapSet.new())
     |> assign(:lifecycle_menu_open, nil)
     |> assign(:importing, false)
     |> assign(:suggestions, [])
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:include_subdomains, false)
     |> assign(:bulk_action, nil)
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

    socket =
      if socket.assigns.live_action in [:new, :edit, :import] &&
           !editor?(socket.assigns.current_scope) do
        socket
        |> put_flash(:error, "You don't have permission to perform this action.")
        |> push_patch(to: ~p"/domains")
      else
        socket
      end

    {:noreply, socket}
  end

  defp apply_action(socket, :index, params) do
    search = Map.get(params, "search", "")
    lifecycle = params |> Map.get("lifecycle", "") |> parse_lifecycle()
    page = params |> Map.get("page", "1") |> Integer.parse() |> elem(0)

    # Clear selection when filters change
    prev_search = socket.assigns[:search] || ""
    prev_lifecycle = socket.assigns[:lifecycle_filter]
    filters_changed = search != prev_search || lifecycle != prev_lifecycle

    result = Domains.list_domains_filtered(search: search, lifecycle: lifecycle, page: page)

    socket
    |> assign(:page_title, "Domains")
    |> assign(:domain, nil)
    |> assign(:domains, result.domains)
    |> assign(:total, result.total)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:search, search)
    |> assign(:lifecycle_filter, lifecycle)
    |> then(fn s ->
      if filters_changed, do: assign(s, :selected_ids, MapSet.new()), else: s
    end)
  end

  defp apply_action(socket, :new, _params) do
    changeset = Domains.change_domain(%Domain{})

    socket
    |> assign(:page_title, "New Domain")
    |> assign(:domain, %Domain{})
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :import, _params) do
    socket
    |> assign(:page_title, "Import Domains")
    |> assign(:domain, nil)
    |> assign(:import_results, nil)
    |> assign(:importing, false)
  end

  defp parse_lifecycle(""), do: nil
  defp parse_lifecycle(nil), do: nil

  defp parse_lifecycle(s) do
    valid = [
      :priority,
      :active,
      :placeholder,
      :under_review,
      :deprecated,
      :decommissioned,
      :abandoned
    ]

    atom = String.to_existing_atom(s)
    if atom in valid, do: atom, else: nil
  rescue
    _ -> nil
  end

  # ── Search & suggestions ────────────────────────────────────────────────────

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

  def handle_event("filter_lifecycle", %{"lifecycle" => lc}, socket) do
    params = build_params(socket, lifecycle: lc, page: 1)
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/domains")}
  end

  def handle_event("paginate", %{"page" => page_str}, socket) do
    page = page_str |> Integer.parse() |> elem(0)
    params = build_params(socket, page: page)
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  # ── Selection mode ──────────────────────────────────────────────────────────

  def handle_event("enter_selection_mode", _params, socket) do
    {:noreply, assign(socket, :selection_mode, true)}
  end

  def handle_event("exit_selection_mode", _params, socket) do
    {:noreply,
     socket
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:include_subdomains, false)
     |> assign(:bulk_action, nil)}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected = socket.assigns.selected_ids

    new_selected =
      if MapSet.member?(selected, id) do
        MapSet.delete(selected, id)
      else
        MapSet.put(selected, id)
      end

    {:noreply, assign(socket, :selected_ids, new_selected)}
  end

  def handle_event("select_all_matching", _params, socket) do
    ids =
      Domains.ids_matching_filters(
        search: socket.assigns.search,
        lifecycle: socket.assigns.lifecycle_filter
      )
      |> Enum.map(&to_string/1)

    {:noreply, assign(socket, :selected_ids, MapSet.new(ids))}
  end

  def handle_event("select_visible", _params, socket) do
    ids = socket.assigns.domains |> Enum.map(&to_string(&1.id))
    {:noreply, assign(socket, :selected_ids, MapSet.new(ids))}
  end

  def handle_event("toggle_include_subdomains", _params, socket) do
    {:noreply, assign(socket, :include_subdomains, !socket.assigns.include_subdomains)}
  end

  def handle_event("bulk_action_confirm", %{"action" => action}, socket) do
    {:noreply, assign(socket, :bulk_action, String.to_existing_atom(action))}
  end

  def handle_event("bulk_action_cancel", _params, socket) do
    {:noreply, assign(socket, :bulk_action, nil)}
  end

  def handle_event("bulk_action_execute", _params, socket) do
    case socket.assigns.bulk_action do
      :delete -> execute_bulk_delete(socket)
      :scan -> execute_bulk_scan(socket)
      _ -> {:noreply, socket}
    end
  end

  # ── Quick scan ──────────────────────────────────────────────────────────────

  def handle_event("quick_scan", %{"id" => id}, socket) do
    domain_id = String.to_integer(id)
    liveview_pid = self()

    Task.start(fn ->
      Scans.run_dnsx_scan(domain_id)
      Scans.run_httpx_scan(domain_id)
      Scans.run_rdap_scan(domain_id)
      Scans.run_subdomain_scan(domain_id)
      send(liveview_pid, {:quick_scan_done, domain_id})
    end)

    {:noreply, put_flash(socket, :info, "Scan started")}
  end

  def handle_info({:quick_scan_done, _domain_id}, socket) do
    params = build_params(socket)
    {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
  end

  # ── Domain CRUD ─────────────────────────────────────────────────────────────

  def handle_event("validate", %{"domain" => domain_params}, socket) do
    changeset =
      socket.assigns.domain
      |> Domains.change_domain(domain_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"domain" => domain_params}, socket) do
    case Domains.create_domain(domain_params) do
      {:ok, _domain} ->
        {:noreply,
         socket
         |> put_flash(:info, "Domain created successfully")
         |> push_patch(to: ~p"/domains")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("open_lifecycle_menu", %{"id" => id}, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, id)}
  end

  def handle_event("close_lifecycle_menu", _, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, nil)}
  end

  def handle_event("set_lifecycle", %{"id" => id, "state" => state}, socket) do
    if !editor?(socket.assigns.current_scope) do
      {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
    else
      domain = Domains.get_domain!(id)

      case Domains.update_domain(domain, %{lifecycle_state: state}) do
        {:ok, _} ->
          params = build_params(socket)

          {:noreply,
           socket
           |> assign(:lifecycle_menu_open, nil)
           |> push_patch(to: ~p"/domains?#{params}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update lifecycle")}
      end
    end
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    # Ignore expand clicks when in selection mode — treat as toggle_select
    if socket.assigns.selection_mode do
      handle_event("toggle_select", %{"id" => id}, socket)
    else
      expanded = socket.assigns.expanded_domains

      new_expanded =
        if MapSet.member?(expanded, id) do
          MapSet.delete(expanded, id)
        else
          MapSet.put(expanded, id)
        end

      {:noreply, assign(socket, :expanded_domains, new_expanded)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if !editor?(socket.assigns.current_scope) do
      {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
    else
      domain = Domains.get_domain!(id)
      {:ok, _} = Domains.delete_domain(domain)
      params = build_params(socket)
      {:noreply, push_patch(socket, to: ~p"/domains?#{params}")}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/domains")}
  end

  # ── Import ──────────────────────────────────────────────────────────────────

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("clear_import_results", _params, socket) do
    {:noreply, assign(socket, :import_results, nil)}
  end

  def handle_event("import", %{"import" => %{"domains" => domains_text}}, socket) do
    run_import(domains_text, socket)
  end

  def handle_event("import_file", _params, socket) do
    entries = socket.assigns.uploads.domains_file.entries

    if Enum.empty?(entries) do
      {:noreply, put_flash(socket, :error, "No file selected")}
    else
      text =
        consume_uploaded_entries(socket, :domains_file, fn %{path: path}, _entry ->
          {:ok, File.read!(path)}
        end)
        |> List.first()

      run_import(text || "", assign(socket, :importing, true))
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp execute_bulk_delete(socket) do
    if !editor?(socket.assigns.current_scope) do
      {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
    else
      ids = socket.assigns.selected_ids |> MapSet.to_list() |> Enum.map(&String.to_integer/1)
      {:ok, count} = Domains.bulk_delete(ids)

      params = build_params(socket)

      {:noreply,
       socket
       |> assign(:selection_mode, false)
       |> assign(:selected_ids, MapSet.new())
       |> assign(:include_subdomains, false)
       |> assign(:bulk_action, nil)
       |> put_flash(:info, "Deleted #{count} domain#{if count != 1, do: "s", else: ""}")
       |> push_patch(to: ~p"/domains?#{params}")}
    end
  end

  defp execute_bulk_scan(socket) do
    ids = socket.assigns.selected_ids |> MapSet.to_list() |> Enum.map(&String.to_integer/1)
    include_subdomains = socket.assigns.include_subdomains

    domains = Enum.map(ids, &Domains.get_domain_with_preloads!/1)

    scan_targets =
      if include_subdomains do
        domains ++ Enum.flat_map(domains, & &1.subdomains)
      else
        domains
      end

    Task.async_stream(
      scan_targets,
      fn domain ->
        Scans.run_dnsx_scan(domain.id)
        Scans.run_httpx_scan(domain.id)
        Scans.run_rdap_scan(domain.id)
        Scans.run_subdomain_scan(domain.id)
      end,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()

    count = length(scan_targets)
    params = build_params(socket)

    {:noreply,
     socket
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:include_subdomains, false)
     |> assign(:bulk_action, nil)
     |> put_flash(:info, "Scanned #{count} domain#{if count != 1, do: "s", else: ""}")
     |> push_patch(to: ~p"/domains?#{params}")}
  end

  defp run_import(text, socket) do
    results = Domains.bulk_import(text)

    {:noreply,
     socket
     |> assign(:importing, false)
     |> assign(:import_results, results)}
  end

  defp build_params(socket, overrides \\ []) do
    search = Keyword.get(overrides, :search, socket.assigns[:search] || "")
    page = Keyword.get(overrides, :page, socket.assigns[:page] || 1)

    lifecycle =
      case Keyword.get(overrides, :lifecycle, socket.assigns[:lifecycle_filter]) do
        nil -> ""
        atom when is_atom(atom) -> Atom.to_string(atom)
        str -> str
      end

    [search: search, lifecycle: lifecycle, page: page]
    |> Enum.reject(fn {_, v} -> v == "" or v == 1 end)
  end

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
  defp lifecycle_color(:deprecated), do: "bg-orange-500"
  defp lifecycle_color(:decommissioned), do: "bg-red-500"
  defp lifecycle_color(:abandoned), do: "bg-neutral-400"
  defp lifecycle_color(_), do: "bg-neutral-400"

  defp lifecycle_options do
    [
      {:priority, "Priority", "bg-teal-600"},
      {:active, "Active", "bg-green-500"},
      {:placeholder, "Placeholder", "bg-violet-500"},
      {:under_review, "Under review", "bg-yellow-500"},
      {:deprecated, "Deprecated", "bg-orange-500"},
      {:decommissioned, "Decommissioned", "bg-red-500"},
      {:abandoned, "Abandoned", "bg-neutral-400"}
    ]
  end

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
end
