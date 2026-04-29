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
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Brand")
    |> assign(:brand, %Brand{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Brand")
    |> assign(:brand, Inventory.get_brand!(id))
  end

  @impl true
  def handle_event("save", %{"brand" => attrs}, socket) do
    brand = socket.assigns.brand

    result =
      if brand.id do
        Inventory.update_brand(brand, attrs)
      else
        Inventory.create_brand(attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Brand saved")
         |> push_patch(to: ~p"/admin/brands")}

      {:error, changeset} ->
        {:noreply, assign(socket, :brand, changeset)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    Inventory.delete_brand(Inventory.get_brand!(id))

    {:noreply,
     socket
     |> put_flash(:info, "Brand deleted")
     |> assign(:brands, Inventory.list_brands())}
  end
end
