defmodule RavnerWeb.AdminLive.PersonLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Accounts
  alias Ravner.Inventory
  alias Ravner.Inventory.OwnershipStats
  alias Ravner.Inventory.Person

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "People")
     |> assign(:active_tab, :people)
     |> assign(:orgs, Inventory.list_organizations())
     |> assign(:users, Accounts.list_users())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    query = params["q"] || ""
    org_id = params["org_id"]

    opts = [
      scope: socket.assigns.current_scope,
      actor: socket.assigns.current_scope.user
    ]

    opts =
      if org_id && org_id != "" do
        Keyword.put(opts, :organization_id, org_id)
      else
        opts
      end

    all_people = Inventory.list_people(opts)

    filtered_people =
      if query != "" do
        q_down = String.downcase(query)

        Enum.filter(all_people, fn p ->
          full_name = String.downcase("#{p.first_name} #{p.last_name}")
          email = String.downcase(p.email || "")
          title = String.downcase(p.title || "")

          String.contains?(full_name, q_down) or String.contains?(email, q_down) or
            String.contains?(title, q_down)
        end)
      else
        all_people
      end

    socket
    |> assign(:page_title, "People")
    |> assign(:people, filtered_people)
    |> assign(:total_count, length(all_people))
    |> assign(:search_query, query)
    |> assign(:selected_org_id, org_id)
    |> assign(:form, nil)
    |> assign(:person, nil)
    |> assign(:stats, nil)
  end

  defp apply_action(socket, :new, params) do
    user_id = params["user_id"]

    initial_params =
      if user_id && user_id != "" do
        case Enum.find(socket.assigns.users, &(to_string(&1.id) == to_string(user_id))) do
          nil ->
            %{}

          user ->
            name_parts = (user.name || "") |> String.trim() |> String.split(" ", parts: 2)
            first_name = Enum.at(name_parts, 0, "")
            last_name = Enum.at(name_parts, 1, "")

            %{
              "user_id" => user.id,
              "email" => user.email,
              "first_name" => first_name,
              "last_name" => last_name
            }
        end
      else
        %{}
      end

    form =
      AshPhoenix.Form.for_create(Person, :create,
        as: "person",
        actor: socket.assigns.current_scope.user
      )

    form =
      if initial_params != %{} do
        AshPhoenix.Form.validate(form, initial_params)
      else
        form
      end

    socket
    |> assign(:page_title, "New Person")
    |> assign(:person, %Person{})
    |> assign(:stats, nil)
    |> assign(:form, to_form(form))
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
  def handle_event("search", %{"q" => query}, socket) do
    params = %{"q" => query}

    params =
      if socket.assigns.selected_org_id && socket.assigns.selected_org_id != "",
        do: Map.put(params, "org_id", socket.assigns.selected_org_id),
        else: params

    {:noreply, push_patch(socket, to: ~p"/admin/people?#{params}")}
  end

  @impl true
  def handle_event("filter_org", %{"org_id" => org_id}, socket) do
    params = %{"org_id" => org_id}

    params =
      if socket.assigns.search_query != "",
        do: Map.put(params, "q", socket.assigns.search_query),
        else: params

    {:noreply, push_patch(socket, to: ~p"/admin/people?#{params}")}
  end

  @impl true
  def handle_event("validate", %{"person" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("save", %{"person" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, _person} ->
        {:noreply,
         socket
         |> put_flash(:info, "Person saved")
         |> push_navigate(to: ~p"/admin/people")}

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
         |> push_navigate(to: ~p"/admin/people")}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to perform this action.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete person.")}
    end
  end
end
