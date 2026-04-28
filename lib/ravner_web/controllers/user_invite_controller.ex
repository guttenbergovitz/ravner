defmodule RavnerWeb.UserInviteController do
  use RavnerWeb, :controller

  alias Ravner.Accounts

  def show(conn, %{"token" => token}) do
    case Accounts.get_valid_invite(token) do
      nil ->
        conn
        |> put_flash(:error, "This invite link is invalid or has expired.")
        |> redirect(to: ~p"/users/log-in")

      invite ->
        render(conn, :show, invite: invite, token: token)
    end
  end

  def create(conn, %{"token" => token, "user" => %{"password" => password}}) do
    case Accounts.get_valid_invite(token) do
      nil ->
        conn
        |> put_flash(:error, "This invite link is invalid or has expired.")
        |> redirect(to: ~p"/users/log-in")

      invite ->
        case Accounts.accept_invite(invite, password) do
          {:ok, user} ->
            conn
            |> put_flash(:info, "Account created! Please log in.")
            |> RavnerWeb.UserAuth.log_in_user(user)

          {:error, _reason} ->
            conn
            |> put_flash(
              :error,
              "Could not create account. Please check your password and try again."
            )
            |> render(:show, invite: invite, token: token)
        end
    end
  end
end
