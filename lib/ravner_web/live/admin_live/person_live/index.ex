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
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Person")
    |> assign(:people, Inventory.list_people())
    |> assign(:person, %Person{})
    |> assign(:form, to_form(Inventory.change_person(%Person{}), as: :person))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    person = Inventory.get_person!(id)

    socket
    |> assign(:page_title, "Edit Person")
    |> assign(:people, Inventory.list_people())
    |> assign(:person, person)
    |> assign(:form, to_form(Inventory.change_person(person), as: :person))
  end

  @impl true
  def handle_event("save", %{"person" => attrs}, socket) do
    person = socket.assigns.person
    person_id = person && person.id
    actor = socket.assigns.current_scope.user

    result =
      if person_id do
        Inventory.update_person(person, attrs, actor: actor)
      else
        Inventory.create_person(attrs, actor: actor)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Person saved")
         |> push_patch(to: ~p"/admin/people")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :person))}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    case Inventory.delete_person(Inventory.get_person!(id), actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Person deleted")
         |> assign(:people, Inventory.list_people())}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete person.")}
    end
  end
end
