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
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Organization")
    |> assign(:org, %Organization{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Organization")
    |> assign(:org, Inventory.get_organization!(id))
  end

  @impl true
  def handle_event("save", %{"organization" => attrs}, socket) do
    org = socket.assigns.org

    result =
      if org.id do
        Inventory.update_organization(org, attrs)
      else
        Inventory.create_organization(attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Organization saved")
         |> push_patch(to: ~p"/admin/organizations")}

      {:error, changeset} ->
        {:noreply, assign(socket, :org, changeset)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    Inventory.delete_organization(Inventory.get_organization!(id))

    {:noreply,
     socket
     |> put_flash(:info, "Organization deleted")
     |> assign(:orgs, Inventory.list_organizations())}
  end
end
