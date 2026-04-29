defmodule RavnerWeb.AdminLive.PersonLive.Show do
  use RavnerWeb, :live_view

  alias Ravner.Inventory

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    person = Inventory.get_person!(id)
    roles = Inventory.list_project_roles_for_person(person.id)

    {:noreply,
     socket
     |> assign(:page_title, "#{person.first_name} #{person.last_name}")
     |> assign(:person, person)
     |> assign(:roles, roles)}
  end
end
