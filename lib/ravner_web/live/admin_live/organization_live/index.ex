defmodule RavnerWeb.AdminLive.OrganizationLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.Organization
  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Organizations")
     |> assign(:brands, Inventory.list_brands())
     |> assign(:people, Inventory.list_people())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Organization")
    |> assign(:org, %Organization{})
    |> assign(:stats, nil)
    |> assign(:form, nil)
    |> assign(
      :form,
      AshPhoenix.Form.for_create(Organization, :create,
        as: "organization",
        actor: socket.assigns.current_scope.user
      )
      |> to_form()
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    org = Inventory.get_organization!(id)

    socket
    |> assign(:page_title, "Edit Organization")
    |> assign(:org, org)
    |> assign(:stats, OwnershipStats.organization_stats(id))
    |> assign(:form, nil)
    |> assign(
      :form,
      AshPhoenix.Form.for_update(org, :update,
        as: "organization",
        actor: socket.assigns.current_scope.user
      )
      |> to_form()
    )
  end

  @impl true
  def handle_event("validate", %{"organization" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("save", %{"organization" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, org} ->
        {:noreply,
         socket
         |> put_flash(:info, "Organization saved")
         |> push_navigate(to: ~p"/ownership/organizations/#{org.id}")}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  @impl true
  def handle_event("delete", _, socket) do
    org = socket.assigns.org
    actor = socket.assigns.current_scope.user

    case Inventory.delete_organization(org, actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Organization deleted")
         |> push_navigate(to: ~p"/ownership")}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete organization.")}
    end
  end
end
