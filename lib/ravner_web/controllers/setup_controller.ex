defmodule RavnerWeb.SetupController do
  use RavnerWeb, :controller

  alias Ravner.Accounts
  alias Ravner.Accounts.User
  alias Ravner.Repo

  def new(conn, _params) do
    if Accounts.has_users?() do
      redirect(conn, to: ~p"/")
    else
      changeset = Accounts.change_user_email(%Ravner.Accounts.User{})
      render(conn, :new, changeset: changeset)
    end
  end

  def create(conn, %{"user" => user_params}) do
    if Accounts.has_users?() do
      redirect(conn, to: ~p"/")
    else
      case Accounts.register_user_with_password(user_params) do
        {:ok, user} ->
          # Confirm the root user immediately and grant admin role
          user
          |> User.confirm_changeset()
          |> Repo.update!()

          Ravner.Accounts.admin_update_user(user, %{role: :admin})

          conn
          |> put_flash(:info, "Root account created. Please log in.")
          |> redirect(to: ~p"/users/log-in")

        {:error, changeset} ->
          render(conn, :new, changeset: changeset)
      end
    end
  end
end
