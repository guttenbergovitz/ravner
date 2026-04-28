defmodule RavnerWeb.DomainLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Domains
  alias Ravner.Domains.Domain

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:domains, Domains.list_domains_with_preloads())
     |> assign(:expanded_domains, MapSet.new())
     |> assign(:lifecycle_menu_open, nil)
     |> assign(:importing, false)
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

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Domains")
    |> assign(:domain, nil)
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

  @impl true
  def handle_event("validate", %{"domain" => domain_params}, socket) do
    changeset =
      socket.assigns.domain
      |> Domains.change_domain(domain_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"domain" => domain_params}, socket) do
    case Domains.create_domain(domain_params) do
      {:ok, domain} ->
        domain = Domains.get_domain_with_preloads!(domain.id)

        {:noreply,
         socket
         |> put_flash(:info, "Domain created successfully")
         |> push_navigate(to: ~p"/domains")
         |> update(:domains, fn domains -> [domain | domains] end)}

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
          domains = Domains.list_domains_with_preloads()

          {:noreply,
           socket
           |> assign(:domains, domains)
           |> assign(:lifecycle_menu_open, nil)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update lifecycle")}
      end
    end
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_domains

    new_expanded =
      if MapSet.member?(expanded, id) do
        MapSet.delete(expanded, id)
      else
        MapSet.put(expanded, id)
      end

    {:noreply, assign(socket, :expanded_domains, new_expanded)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if !editor?(socket.assigns.current_scope) do
      {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
    else
      domain = Domains.get_domain!(id)
      {:ok, _} = Domains.delete_domain(domain)

      {:noreply,
       update(socket, :domains, fn domains -> Enum.reject(domains, &(&1.id == domain.id)) end)}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/domains")}
  end

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

  defp run_import(text, socket) do
    results = Domains.bulk_import(text)

    socket =
      Enum.reduce(results.added, socket, fn name, acc ->
        case Domains.find_domain_by_name(name) do
          nil ->
            acc

          domain ->
            domain = Domains.get_domain_with_preloads!(domain.id)
            update(acc, :domains, fn domains -> [domain | domains] end)
        end
      end)

    {:noreply,
     socket
     |> assign(:importing, false)
     |> assign(:import_results, results)}
  end

  defp editor?(nil), do: false

  defp editor?(scope) do
    role_rank = %{viewer: 0, editor: 1, admin: 2}
    user = scope.user
    user && Map.get(role_rank, user.role, 0) >= 1
  end

  defp lifecycle_color(:active), do: "bg-green-500"
  defp lifecycle_color(:under_review), do: "bg-yellow-500"
  defp lifecycle_color(:deprecated), do: "bg-orange-500"
  defp lifecycle_color(:decommissioned), do: "bg-red-500"
  defp lifecycle_color(:abandoned), do: "bg-neutral-400"
  defp lifecycle_color(_), do: "bg-neutral-400"

  defp lifecycle_options do
    [
      {:active, "Active", "bg-green-500"},
      {:under_review, "Under review", "bg-yellow-500"},
      {:deprecated, "Deprecated", "bg-orange-500"},
      {:decommissioned, "Decommissioned", "bg-red-500"},
      {:abandoned, "Abandoned", "bg-neutral-400"}
    ]
  end
end

# This line intentionally left to trigger read - please ignore
