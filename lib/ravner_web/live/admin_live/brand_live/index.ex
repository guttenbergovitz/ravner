defmodule RavnerWeb.AdminLive.BrandLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.Brand
  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Brands")
     |> assign(:people, Inventory.list_people())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Brand")
    |> assign(:brand, %Brand{})
    |> assign(:stats, nil)
    |> assign(:form, nil)
    |> assign(
      :form,
      AshPhoenix.Form.for_create(Brand, :create,
        as: "brand",
        actor: socket.assigns.current_scope.user
      )
      |> to_form()
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    brand = Inventory.get_brand!(id)

    socket
    |> assign(:page_title, "Edit Brand")
    |> assign(:brand, brand)
    |> assign(:stats, OwnershipStats.brand_stats(id))
    |> assign(:form, nil)
    |> assign(
      :form,
      AshPhoenix.Form.for_update(brand, :update,
        as: "brand",
        actor: socket.assigns.current_scope.user
      )
      |> to_form()
    )
  end

  @impl true
  def handle_event("validate", %{"brand" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("save", %{"brand" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, brand} ->
        {:noreply,
         socket
         |> put_flash(:info, "Brand saved")
         |> push_navigate(to: ~p"/ownership/brands/#{brand.id}")}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  @impl true
  def handle_event("delete", _, socket) do
    brand = socket.assigns.brand
    actor = socket.assigns.current_scope.user

    case Inventory.delete_brand(brand, actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Brand deleted")
         |> push_navigate(to: ~p"/ownership")}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete brand.")}
    end
  end
end
