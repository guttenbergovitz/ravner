defmodule RavnerWeb.AdminLive.OrganizationLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.Organization

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Organizations")
     |> assign(:brands, Inventory.list_brands())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Organizations")
    |> assign(:orgs, Inventory.list_organizations())
    |> assign(:org, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Organization")
    |> assign(:orgs, Inventory.list_organizations())
    |> assign(:org, %Organization{})
    |> assign(:form, to_form(Inventory.change_organization(%Organization{}), as: :organization))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    org = Inventory.get_organization!(id)

    socket
    |> assign(:page_title, "Edit Organization")
    |> assign(:orgs, Inventory.list_organizations())
    |> assign(:org, org)
    |> assign(:form, to_form(Inventory.change_organization(org), as: :organization))
  end

  @impl true
  def handle_event("save", %{"organization" => attrs}, socket) do
    org = socket.assigns.organization
    org_id = org && org.id
    actor = socket.assigns.current_scope.user

    result =
      if org_id do
        Inventory.update_organization(org, attrs, actor: actor)
      else
        Inventory.create_organization(attrs, actor: actor)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Organization saved")
         |> push_patch(to: ~p"/admin/organizations")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :organization))}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    case Inventory.delete_organization(Inventory.get_organization!(id), actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Organization deleted")
         |> assign(:organizations, Inventory.list_organizations())}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete organization.")}
    end
  end
end
