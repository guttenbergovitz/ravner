defmodule RavnerWeb.AdminLive.BrandLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.Brand

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Brands")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Brands")
    |> assign(:brands, Inventory.list_brands())
    |> assign(:brand, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Brand")
    |> assign(:brands, Inventory.list_brands())
    |> assign(:brand, %Brand{})
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
    |> assign(:brands, Inventory.list_brands())
    |> assign(:brand, brand)
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
      {:ok, _brand} ->
        {:noreply,
         socket
         |> put_flash(:info, "Brand saved")
         |> push_patch(to: ~p"/admin/brands")}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    case Inventory.delete_brand(Inventory.get_brand!(id), actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Brand deleted")
         |> assign(:brands, Inventory.list_brands())}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to perform this action.")}
        
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete brand.")}
    end
  end
end
