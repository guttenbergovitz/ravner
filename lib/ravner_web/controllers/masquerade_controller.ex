defmodule RavnerWeb.MasqueradeController do
  @moduledoc """
  Controller managing administrator masquerade (persona switching) sessions.

  Allows root administrators to temporarily assume the identity of any active user
  to verify UI rendering, live scope resolution, and Ash policy access boundaries.
  A persistent top-level banner is displayed during masquerade sessions, allowing
  instant restoration of the original administrator session via `delete/2`.
  """
  use RavnerWeb, :controller

  alias Ravner.Accounts
  alias Ravner.Accounts.User

  @doc """
  Initiates a masquerade session for a top-level administrator.

  Accepts either a `:user_id` route parameter or a `:user_id` / `:user_email` form parameter.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    current_user = conn.assigns[:current_scope] && conn.assigns[:current_scope].user

    if is_nil(current_user) or current_user.role != :admin do
      conn
      |> put_flash(:error, "You do not have permission to masquerade as another user.")
      |> redirect(to: ~p"/domains")
    else
      target_user = find_target_user(params)

      case target_user do
        nil ->
          conn
          |> put_flash(:error, "User not found.")
          |> redirect(to: ~p"/admin/users")

        %User{active: false} ->
          conn
          |> put_flash(:error, "Cannot masquerade as an inactive user.")
          |> redirect(to: ~p"/admin/users")

        %User{id: target_id} when target_id == current_user.id ->
          conn
          |> put_flash(:error, "You are already logged in as this user.")
          |> redirect(to: ~p"/admin/users")

        %User{} = target ->
          do_masquerade(conn, current_user, target)
      end
    end
  end

  @doc """
  Terminates an active masquerade session and restores the original administrator session.
  """
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    admin_token = get_session(conn, :masquerading_admin_token)

    if is_nil(admin_token) do
      conn
      |> put_flash(:error, "You are not currently masquerading as another user.")
      |> redirect(to: ~p"/dashboard")
    else
      case Accounts.get_user_by_session_token(admin_token) do
        {%User{} = admin_user, _token_inserted_at} ->
          # Clean up temporary session token created for target user
          current_token = get_session(conn, :user_token)
          if current_token, do: Accounts.delete_user_session_token(current_token)

          # Disconnect live socket so LiveViews re-mount under administrator
          if live_socket_id = get_session(conn, :live_socket_id) do
            RavnerWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
          end

          conn
          |> put_session(:user_token, admin_token)
          |> delete_session(:masquerading_admin_token)
          |> delete_session(:masquerading_admin_email)
          |> delete_session(:masquerading_admin_id)
          |> put_flash(:info, "Switched back to #{admin_user.email} (Administrator).")
          |> redirect(to: ~p"/admin/users")

        nil ->
          # Admin token has expired or been revoked in database
          conn
          |> delete_session(:masquerading_admin_token)
          |> delete_session(:masquerading_admin_email)
          |> delete_session(:masquerading_admin_id)
          |> RavnerWeb.UserAuth.log_out_user()
          |> put_flash(:error, "Administrator session expired. Please log in again.")
      end
    end
  end

  defp find_target_user(params) do
    cond do
      id = params["user_id"] || params["target_user_id"] ->
        case Integer.parse(to_string(id)) do
          {int_id, ""} ->
            try do
              Accounts.get_user!(int_id)
            rescue
              _ -> nil
            end

          _ ->
            nil
        end

      email = params["user_email"] ->
        clean_email = email |> to_string() |> String.trim()
        if clean_email != "", do: Accounts.get_user_by_email(clean_email), else: nil

      true ->
        nil
    end
  end

  defp do_masquerade(conn, current_user, target_user) do
    # Preserve original admin token (or preserve existing if nested)
    admin_token = get_session(conn, :masquerading_admin_token) || get_session(conn, :user_token)
    admin_email = get_session(conn, :masquerading_admin_email) || current_user.email
    admin_id = get_session(conn, :masquerading_admin_id) || current_user.id

    # Generate a fresh session token for target user
    target_token = Accounts.generate_user_session_token(target_user)

    # Disconnect live socket so active LiveViews immediately re-mount under target user
    if live_socket_id = get_session(conn, :live_socket_id) do
      RavnerWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    display_identity =
      if target_user.name && target_user.name != "" do
        "#{target_user.name} (#{target_user.email} - #{target_user.role})"
      else
        "#{target_user.email} (#{target_user.role})"
      end

    conn
    |> put_session(:user_token, target_token)
    |> put_session(:masquerading_admin_token, admin_token)
    |> put_session(:masquerading_admin_email, admin_email)
    |> put_session(:masquerading_admin_id, admin_id)
    |> put_flash(:info, "Now masquerading as #{display_identity}.")
    |> redirect(to: ~p"/dashboard")
  end
end
