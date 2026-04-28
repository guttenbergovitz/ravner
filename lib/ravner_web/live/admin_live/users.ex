defmodule RavnerWeb.AdminLive.Users do
  use RavnerWeb, :live_view

  alias Ravner.Accounts
  alias Ravner.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:users, Accounts.list_users())
     |> assign(:page_title, "User Management")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:user, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    changeset = User.admin_changeset(%User{}, %{})

    socket
    |> assign(:user, %User{})
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    user = Enum.find(socket.assigns.users, &(&1.id == String.to_integer(id)))
    changeset = User.role_changeset(user, %{})

    socket
    |> assign(:user, user)
    |> assign(:form, to_form(changeset))
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.user
      |> changeset_for_action(socket.assigns.live_action, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case socket.assigns.live_action do
      :new -> do_create(socket, params)
      :edit -> do_update(socket, params)
    end
  end

  def handle_event("deactivate", %{"id" => id}, socket) do
    user = Enum.find(socket.assigns.users, &(&1.id == String.to_integer(id)))

    case Accounts.admin_update_user(user, %{active: false}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "User deactivated.")
         |> assign(:users, Accounts.list_users())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not deactivate user.")}
    end
  end

  def handle_event("activate", %{"id" => id}, socket) do
    user = Enum.find(socket.assigns.users, &(&1.id == String.to_integer(id)))

    case Accounts.admin_update_user(user, %{active: true}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "User activated.")
         |> assign(:users, Accounts.list_users())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not activate user.")}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/users")}
  end

  defp do_create(socket, params) do
    case Accounts.admin_create_user(params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User created successfully.")
         |> assign(:users, Accounts.list_users())
         |> push_patch(to: ~p"/admin/users")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp do_update(socket, params) do
    case Accounts.admin_update_user(socket.assigns.user, params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User updated.")
         |> assign(:users, Accounts.list_users())
         |> push_patch(to: ~p"/admin/users")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp changeset_for_action(user, :new, params), do: User.admin_changeset(user, params)
  defp changeset_for_action(user, :edit, params), do: User.role_changeset(user, params)
  defp changeset_for_action(user, _, params), do: User.role_changeset(user, params)
end
