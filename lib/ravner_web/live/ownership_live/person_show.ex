defmodule RavnerWeb.OwnershipLive.PersonShow do
  use RavnerWeb, :live_view

  alias Ravner.Inventory
  alias Ravner.Inventory.OwnershipStats

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    person = Inventory.get_person!(id)
    stats = OwnershipStats.person_stats(id)
    roles = OwnershipStats.list_roles_for_person(id)

    {:ok,
     socket
     |> assign(:page_title, "#{person.first_name} #{person.last_name}")
     |> assign(:person, person)
     |> assign(:stats, stats)
     |> assign(:roles, roles)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end
