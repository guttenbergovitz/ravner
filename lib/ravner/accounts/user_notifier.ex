defmodule Ravner.Accounts.UserNotifier do
  @moduledoc """
  Sends emails to users for account-related actions.
  """
  import Swoosh.Email

  alias Ravner.Accounts.User
  alias Ravner.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    sender = Application.get_env(:ravner, :mail_from, "noreply@example.com")

    email =
      new()
      |> to(recipient)
      |> from({"Ravner", sender})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to reset a user password (admin-initiated).
  """
  def deliver_password_reset_instructions(user, url) do
    deliver(user.email, "Reset password instructions", """

    ==============================

    Hi #{user.email},

    An administrator has requested to reset your password.

    You can reset your password by visiting the URL below:

    #{url}

    If you didn't request this change, please contact your administrator.

    ==============================
    """)
  end

  @doc """
  Deliver a new temporary password to a user (admin-initiated).
  """
  def deliver_new_password_instructions(user, password) do
    deliver(user.email, "Your new password", """

    ==============================

    Hi #{user.email},

    Your password has been reset by an administrator.

    Your new temporary password is: #{password}

    Please log in and change your password as soon as possible.

    ==============================
    """)
  end
end
