defmodule RavnerWeb.UserResetPasswordController do
  use RavnerWeb, :controller

  alias Ravner.Accounts

  def new(conn, %{"token" => token}) do
    if Accounts.get_user_by_reset_password_token(token) do
      form = Phoenix.Component.to_form(%{}, as: "user")
      render(conn, :new, token: token, form: form)
    else
      conn
      |> put_flash(:error, "Reset password link is invalid or it has expired.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def create(conn, %{"user" => %{"token" => token, "password" => password}}) do
    case Accounts.reset_user_password(token, %{"password" => password}) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Password reset successfully. Please log in with your new password.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :invalid_token} ->
        conn
        |> put_flash(:error, "Reset password link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")

      {:error, changeset} ->
        form = Phoenix.Component.to_form(changeset, as: "user")

        conn
        |> put_flash(:error, "Could not reset password.")
        |> render(:new, token: token, form: form)
    end
  end
end
