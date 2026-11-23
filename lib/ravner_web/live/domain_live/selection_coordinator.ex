defmodule RavnerWeb.DomainLive.SelectionCoordinator do
  @moduledoc """
  Coordinates selection mode, bulk actions, and multi-domain operations.
  Extracts complex bulk execution logic from DomainLive.Index.
  """

  alias Ravner.Domains
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  @bulk_actions %{"delete" => :delete, "scan" => :scan, "security_scan" => :security_scan}
  @lifecycle_states %{
    "priority" => :priority,
    "active" => :active,
    "under_review" => :under_review,
    "placeholder" => :placeholder,
    "deprecated" => :deprecated,
    "decommissioned" => :decommissioned,
    "abandoned" => :abandoned
  }

  # ─── Initial State ───────────────────────────────────────────────────────────

  def initial_assigns do
    %{
      selection_mode: false,
      selected_ids: MapSet.new(),
      bulk_include_subdomains: false,
      bulk_action: nil,
      bulk_actions_menu_open: false,
      scanning_ids: MapSet.new(),
      export_include_subs: false
    }
  end

  # ─── Selection Mode ──────────────────────────────────────────────────────────

  def enter_selection_mode(socket) do
    {:noreply, assign(socket, :selection_mode, true)}
  end

  def exit_selection_mode(socket) do
    {:noreply,
     socket
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:bulk_include_subdomains, false)
     |> assign(:bulk_action, nil)
     |> assign(:bulk_actions_menu_open, false)
     |> assign(:scanning_ids, MapSet.new())
     |> assign(:export_include_subs, false)}
  end

  def toggle_select(socket, id) do
    selected = socket.assigns.selected_ids
    new_selected = toggle_mapset(selected, id)
    {:noreply, assign(socket, :selected_ids, new_selected)}
  end

  def select_all_matching(socket, build_params_fn) do
    params = Map.new(build_params_fn.(socket))

    ids =
      ([scope: socket.assigns[:current_scope]] ++ Map.to_list(params))
      |> Domains.ids_matching_filters()
      |> Enum.map(&to_string/1)

    {:noreply, assign(socket, :selected_ids, MapSet.new(ids))}
  end

  def select_visible(socket) do
    ids = Enum.map(socket.assigns.domains, &to_string(&1.id))
    {:noreply, assign(socket, :selected_ids, MapSet.new(ids))}
  end

  def clear_selection(socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new())}
  end

  def toggle_include_subdomains(socket) do
    {:noreply, assign(socket, :bulk_include_subdomains, !socket.assigns.bulk_include_subdomains)}
  end

  def toggle_export_subs(socket) do
    {:noreply, assign(socket, :export_include_subs, !socket.assigns.export_include_subs)}
  end

  # ─── Bulk Actions Menu ───────────────────────────────────────────────────────

  def toggle_bulk_actions_menu(socket) do
    {:noreply, assign(socket, :bulk_actions_menu_open, !socket.assigns.bulk_actions_menu_open)}
  end

  def close_bulk_actions_menu(socket) do
    {:noreply, assign(socket, :bulk_actions_menu_open, false)}
  end

  def bulk_action_confirm(socket, %{"action" => action}) do
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

  def bulk_action_confirm(socket, %{"lifecycle" => state}) do
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

  def bulk_action_confirm(socket, %{"brand_id" => id}) do
    {:noreply,
     socket
     |> assign(:bulk_actions_menu_open, false)
     |> assign(:bulk_action, {:brand, String.to_integer(id)})}
  end

  def bulk_action_confirm(socket, %{"org_id" => id}) do
    {:noreply,
     socket
     |> assign(:bulk_actions_menu_open, false)
     |> assign(:bulk_action, {:org, String.to_integer(id)})}
  end

  def bulk_action_confirm(socket, %{"project_id" => id}) do
    {:noreply,
     socket
     |> assign(:bulk_actions_menu_open, false)
     |> assign(:bulk_action, {:project, String.to_integer(id)})}
  end

  def bulk_action_cancel(socket) do
    {:noreply,
     socket
     |> assign(:bulk_action, nil)
     |> assign(:bulk_actions_menu_open, false)}
  end

  # ─── Bulk Action Execution ───────────────────────────────────────────────────

  def bulk_action_execute(socket, refresh_fn) do
    socket = assign(socket, :bulk_actions_menu_open, false)

    case socket.assigns.bulk_action do
      :delete ->
        execute_bulk_delete(socket, refresh_fn)

      :scan ->
        execute_bulk_scan(socket, refresh_fn)

      :security_scan ->
        execute_bulk_security_scan(socket, refresh_fn)

      {:lifecycle, state} ->
        execute_bulk_lifecycle(socket, state, refresh_fn)

      {type, id} when type in [:brand, :org, :project] ->
        execute_bulk_assign(socket, type, id, refresh_fn)
    end
  end

  defp execute_bulk_delete(socket, refresh_fn) do
    ids = get_target_ids(socket)
    actor = socket.assigns.current_scope.user

    case Domains.bulk_delete(ids, actor: actor) do
      {:ok, count} ->
        socket =
          socket
          |> assign(:selected_ids, MapSet.new())
          |> assign(:bulk_action, nil)
          |> refresh_fn.()

        msg = "Deleted #{count} domain#{if count != 1, do: "s"}."
        {:noreply, put_flash(socket, :info, msg)}

      {:error, :actor_required} ->
        {:noreply, put_flash(socket, :error, "Bulk delete requires an authenticated user.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Bulk delete failed: #{inspect(reason)}")}
    end
  end

  defp execute_bulk_scan(socket, _refresh_fn) do
    ids = get_target_ids(socket)
    user_id = socket.assigns.current_scope.user.id
    topic = "bulk_scans:user:#{user_id}"

    ids
    |> Enum.map(
      &Ravner.Workers.ScanWorker.new(%{
        domain_id: &1,
        scan_type: "quick",
        notify_topic: topic,
        user_id: user_id
      })
    )
    |> Oban.insert_all()

    scanning_ids = ids |> Enum.map(&to_string/1) |> MapSet.new()

    {:noreply,
     socket
     |> assign(:scanning_ids, MapSet.union(socket.assigns.scanning_ids, scanning_ids))
     |> assign(:bulk_action, nil)
     |> put_flash(:info, "Scanning #{MapSet.size(scanning_ids)} domains...")}
  end

  defp execute_bulk_security_scan(socket, _refresh_fn) do
    ids = get_target_ids(socket)
    user_id = socket.assigns.current_scope.user.id
    topic = "bulk_scans:user:#{user_id}"

    ids
    |> Enum.map(
      &Ravner.Workers.ScanWorker.new(%{
        domain_id: &1,
        scan_type: "security_scan",
        notify_topic: topic,
        user_id: user_id
      })
    )
    |> Oban.insert_all()

    scanning_ids = ids |> Enum.map(&to_string/1) |> MapSet.new()

    {:noreply,
     socket
     |> assign(:scanning_ids, MapSet.union(socket.assigns.scanning_ids, scanning_ids))
     |> assign(:bulk_action, nil)
     |> put_flash(:info, "Security scanning #{MapSet.size(scanning_ids)} domains...")}
  end

  defp execute_bulk_lifecycle(socket, state, refresh_fn) do
    ids = get_target_ids(socket)
    actor = socket.assigns.current_scope.user

    case Domains.bulk_set_lifecycle(ids, state, actor: actor) do
      {:ok, count} ->
        socket =
          socket
          |> assign(:selected_ids, MapSet.new())
          |> assign(:bulk_action, nil)
          |> refresh_fn.()

        msg = "Updated #{count} domain#{if count != 1, do: "s"} to #{state}."
        {:noreply, put_flash(socket, :info, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Lifecycle update failed: #{inspect(reason)}")}
    end
  end

  defp execute_bulk_assign(socket, type, target_id, refresh_fn) do
    ids = get_target_ids(socket)
    actor = socket.assigns.current_scope.user

    case Domains.bulk_assign(ids, type, target_id, actor: actor) do
      {:ok, count} ->
        socket =
          socket
          |> assign(:selected_ids, MapSet.new())
          |> assign(:bulk_action, nil)
          |> refresh_fn.()

        label = Atom.to_string(type)
        msg = "Assigned #{label} to #{count} domain#{if count != 1, do: "s"}."
        {:noreply, put_flash(socket, :info, msg)}

      {:error, reason} ->
        label = Atom.to_string(type)
        {:noreply, put_flash(socket, :error, "#{label} assignment failed: #{inspect(reason)}")}
    end
  end

  defp get_target_ids(socket) do
    base_ids =
      socket.assigns.selected_ids
      |> MapSet.to_list()
      |> Enum.map(&String.to_integer/1)

    if socket.assigns.bulk_include_subdomains do
      Domains.list_domains_by_ids(base_ids, scope: socket.assigns.current_scope)
      |> Enum.flat_map(fn d -> [d.id | Enum.map(loaded_subdomains(d), & &1.id)] end)
      |> Enum.uniq()
    else
      Domains.list_domains_by_ids(base_ids, scope: socket.assigns.current_scope)
      |> Enum.map(& &1.id)
    end
  end

  # ─── Quick Scan ──────────────────────────────────────────────────────────────

  def quick_scan(socket, domain_id_str) do
    domain_id = String.to_integer(domain_id_str)
    scope = socket.assigns.current_scope
    domain = Domains.get_domain!(domain_id)

    cond do
      not Ravner.Accounts.ScopeResolver.can_scan_domain?(scope, domain) ->
        {:noreply, put_flash(socket, :error, "You do not have permission to scan this domain.")}

      not Ravner.Domains.Domain.scannable?(domain) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Scanning is disabled for #{domain.lifecycle_state} domains."
         )}

      true ->
        user_id = scope.user.id
        topic = "bulk_scans:user:#{user_id}"

        %{domain_id: domain_id, scan_type: "quick", notify_topic: topic, user_id: user_id}
        |> Ravner.Workers.ScanWorker.new()
        |> Oban.insert()

        {:noreply,
         assign(socket, :scanning_ids, MapSet.put(socket.assigns.scanning_ids, domain_id_str))}
    end
  end

  def scan_visible(socket, refresh_fn) do
    ids = socket.assigns.domains |> Enum.map(& &1.id)
    include_subdomains = socket.assigns.bulk_include_subdomains
    execute_scan_on_ids(socket, ids, include_subdomains, refresh_fn)
  end

  defp execute_scan_on_ids(socket, ids, include_subdomains, _refresh_fn) do
    scope = socket.assigns.current_scope
    user_id = scope.user.id
    topic = "bulk_scans:user:#{user_id}"

    target_ids =
      if include_subdomains do
        Domains.list_domains_by_ids(ids, scope: scope)
        |> Enum.flat_map(fn d -> [d.id | Enum.map(loaded_subdomains(d), & &1.id)] end)
        |> Enum.uniq()
      else
        ids
      end

    permitted_ids =
      Enum.filter(target_ids, &Ravner.Accounts.ScopeResolver.can_scan_domain?(scope, &1))

    if permitted_ids != [] do
      permitted_ids
      |> Enum.map(fn id ->
        %{domain_id: id, scan_type: "quick", notify_topic: topic, user_id: user_id}
        |> Ravner.Workers.ScanWorker.new()
      end)
      |> Oban.insert_all()

      scanning_ids = permitted_ids |> Enum.map(&to_string/1) |> MapSet.new()

      {:noreply,
       socket
       |> assign(:scanning_ids, MapSet.union(socket.assigns.scanning_ids, scanning_ids))
       |> put_flash(:info, "Scanning #{MapSet.size(scanning_ids)} domains...")}
    else
      {:noreply, put_flash(socket, :error, "No domains you can scan.")}
    end
  end

  # ─── Scan Complete Handlers ──────────────────────────────────────────────────

  def handle_scan_done(socket, domain_id, refresh_fn) do
    socket =
      socket
      |> assign(:scanning_ids, MapSet.delete(socket.assigns.scanning_ids, "#{domain_id}"))

    {:noreply, refresh_fn.(socket)}
  end

  # ─── Helpers ─────────────────────────────────────────────────────────────────

  defp loaded_subdomains(%{subdomains: subs}) when is_list(subs), do: subs
  defp loaded_subdomains(_), do: []

  defp toggle_mapset(set, item) do
    if MapSet.member?(set, item) do
      MapSet.delete(set, item)
    else
      MapSet.put(set, item)
    end
  end
end
