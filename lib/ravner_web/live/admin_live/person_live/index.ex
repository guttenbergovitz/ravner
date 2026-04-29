defmodule RavnerWeb.AdminLive.PersonLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.Person

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "People")
     |> assign(:orgs, Inventory.list_organizations())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "People")
    |> assign(:people, Inventory.list_people())
    |> assign(:person, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Person")
    |> assign(:person, %Person{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Person")
    |> assign(:person, Inventory.get_person!(id))
  end

  @impl true
  def handle_event("save", %{"person" => attrs}, socket) do
    person = socket.assigns.person

    result =
      if person.id do
        Inventory.update_person(person, attrs)
      else
        Inventory.create_person(attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Person saved")
         |> push_patch(to: ~p"/admin/people")}

      {:error, changeset} ->
        {:noreply, assign(socket, :person, changeset)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    Inventory.delete_person(Inventory.get_person!(id))

    {:noreply,
     socket
     |> put_flash(:info, "Person deleted")
     |> assign(:people, Inventory.list_people())}
  end
end
