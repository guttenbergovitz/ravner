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

    if is_nil(user) do
      socket
      |> put_flash(:error, "User not found.")
      |> push_patch(to: ~p"/admin/users")
    else
      changeset = User.role_changeset(user, %{})

      socket
      |> assign(:user, user)
      |> assign(:form, to_form(changeset))
      |> assign(:manual_password_form, to_form(User.password_changeset(user, %{})))
    end
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

    case Accounts.admin_update_user(user, %{active: false},
           actor: socket.assigns.current_scope.user
         ) do
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

    case Accounts.admin_update_user(user, %{active: true},
           actor: socket.assigns.current_scope.user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "User activated.")
         |> assign(:users, Accounts.list_users())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not activate user.")}
    end
  end

  def handle_event("reset_password_token", %{"id" => id}, socket) do
    user = Enum.find(socket.assigns.users, &(&1.id == String.to_integer(id)))

    url_fun = fn token ->
      Phoenix.VerifiedRoutes.url(socket, ~p"/users/reset-password/#{token}")
    end

    case Accounts.admin_reset_password_token(user, url_fun) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password reset link sent to #{user.email}.")
         |> assign(:users, Accounts.list_users())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not send password reset link.")}
    end
  end

  def handle_event("reset_password_random", %{"id" => id}, socket) do
    user = Enum.find(socket.assigns.users, &(&1.id == String.to_integer(id)))

    case Accounts.admin_reset_password_random(user) do
      {:ok, _updated_user} ->
        {:noreply,
         socket
         |> put_flash(:info, "New random password sent to #{user.email}.")
         |> assign(:users, Accounts.list_users())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not reset password.")}
    end
  end

  def handle_event("reset_password_manual", %{"user" => params}, socket) do
    case Accounts.admin_reset_password_manual(socket.assigns.user, params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password updated successfully.")
         |> assign(:users, Accounts.list_users())
         |> assign(
           :manual_password_form,
           to_form(User.password_changeset(socket.assigns.user, %{}))
         )
         |> push_patch(to: ~p"/admin/users")}

      {:error, changeset} ->
        {:noreply, assign(socket, :manual_password_form, to_form(changeset))}
    end
  end

  def handle_event("delete_user", %{"id" => id}, socket) do
    user = Enum.find(socket.assigns.users, &(&1.id == String.to_integer(id)))

    case Accounts.admin_delete_user(user, actor: socket.assigns.current_scope.user) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "User deleted.")
         |> assign(:users, Accounts.list_users())
         |> push_patch(to: ~p"/admin/users")}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete user.")}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/users")}
  end

  defp do_create(socket, params) do
    case Accounts.admin_create_user(params, actor: socket.assigns.current_scope.user) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User created successfully.")
         |> assign(:users, Accounts.list_users())
         |> push_patch(to: ~p"/admin/users")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Authorization denied — cannot create user.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Could not create user.")}
    end
  end

  defp do_update(socket, params) do
    case Accounts.admin_update_user(socket.assigns.user, params,
           actor: socket.assigns.current_scope.user
         ) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User updated.")
         |> assign(:users, Accounts.list_users())
         |> push_patch(to: ~p"/admin/users")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Authorization denied — cannot update user.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Could not update user.")}
    end
  end

  defp changeset_for_action(user, :new, params) do
    user
    |> User.admin_changeset(params)
    |> User.password_changeset(params)
  end

  defp changeset_for_action(user, :edit, params), do: User.role_changeset(user, params)
  defp changeset_for_action(user, _, params), do: User.role_changeset(user, params)
end
