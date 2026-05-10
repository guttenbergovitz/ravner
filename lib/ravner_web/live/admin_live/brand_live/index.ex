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
    |> assign(:form, to_form(Inventory.change_brand(%Brand{}), as: :brand))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    brand = Inventory.get_brand!(id)

    socket
    |> assign(:page_title, "Edit Brand")
    |> assign(:brands, Inventory.list_brands())
    |> assign(:brand, brand)
    |> assign(:form, to_form(Inventory.change_brand(brand), as: :brand))
  end

  @impl true
  def handle_event("save", %{"brand" => attrs}, socket) do
    brand = socket.assigns.brand
    brand_id = brand && brand.id
    actor = socket.assigns.current_scope.user

    result =
      if brand_id do
        Inventory.update_brand(brand, attrs, actor: actor)
      else
        Inventory.create_brand(attrs, actor: actor)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Brand saved")
         |> push_patch(to: ~p"/admin/brands")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :brand))}
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
