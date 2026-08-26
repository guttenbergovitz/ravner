defmodule RavnerWeb.AdminLive.PersonLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.Person
  alias Ravner.Inventory.OwnershipStats

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

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Person")
    |> assign(:person, %Person{})
    |> assign(:stats, nil)
    |> assign(:form, nil)
    |> assign(
      :form,
      AshPhoenix.Form.for_create(Person, :create,
        as: "person",
        actor: socket.assigns.current_scope.user
      )
      |> to_form()
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    person = Inventory.get_person!(id)

    socket
    |> assign(:page_title, "Edit Person")
    |> assign(:person, person)
    |> assign(:stats, OwnershipStats.person_stats(id))
    |> assign(:form, nil)
    |> assign(
      :form,
      AshPhoenix.Form.for_update(person, :update,
        as: "person",
        actor: socket.assigns.current_scope.user
      )
      |> to_form()
    )
  end

  @impl true
  def handle_event("validate", %{"person" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("save", %{"person" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, person} ->
        {:noreply,
         socket
         |> put_flash(:info, "Person saved")
         |> push_navigate(to: ~p"/ownership/people/#{person.id}")}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  @impl true
  def handle_event("delete", _, socket) do
    person = socket.assigns.person
    actor = socket.assigns.current_scope.user

    case Inventory.delete_person(person, actor: actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Person deleted")
         |> push_navigate(to: ~p"/ownership")}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete person.")}
    end
  end
end
