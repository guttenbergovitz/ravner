defmodule RavnerWeb.MasqueradeControllerTest do
  use RavnerWeb.ConnCase, async: true

  alias Ravner.Accounts
  alias Ravner.AccountsFixtures

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin, name: "Super Admin"})
    viewer = AccountsFixtures.user_fixture(%{role: :viewer, name: "Regular Viewer"})
    {:ok, conn: log_in_user(conn, admin), admin: admin, viewer: viewer}
  end

  describe "POST /admin/masquerade/:user_id" do
    test "admin can masquerade as a viewer and receives masquerading session", %{
      conn: conn,
      admin: admin,
      viewer: viewer
    } do
      conn = post(conn, ~p"/admin/masquerade/#{viewer.id}")

      assert redirected_to(conn) == ~p"/dashboard"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Now masquerading as"

      # Verify session keys
      assert get_session(conn, :masquerading_admin_token) != nil
      assert get_session(conn, :masquerading_admin_email) == admin.email
      assert get_session(conn, :masquerading_admin_id) == admin.id

      # Following request operates under viewer identity
      conn = get(recycle(conn), ~p"/dashboard")
      assert html_response(conn, 200) =~ "masquerade-banner"
      assert html_response(conn, 200) =~ viewer.email
      assert html_response(conn, 200) =~ "Switch back to Admin"
    end

    test "masqueraded viewer cannot access admin routes", %{
      conn: conn,
      viewer: viewer
    } do
      conn = post(conn, ~p"/admin/masquerade/#{viewer.id}")
      assert redirected_to(conn) == ~p"/dashboard"

      # Trying to access /admin/users while masquerading as viewer fails with permission error
      conn = get(recycle(conn), ~p"/admin/users")
      assert redirected_to(conn) == ~p"/domains"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "permission"
    end

    test "admin can masquerade via form POST with user_email parameter", %{
      conn: conn,
      viewer: viewer
    } do
      conn = post(conn, ~p"/admin/masquerade", %{"user_email" => viewer.email})

      assert redirected_to(conn) == ~p"/dashboard"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ viewer.email
    end

    test "cannot masquerade as inactive user", %{conn: conn, admin: admin} do
      inactive = AccountsFixtures.user_fixture(%{role: :viewer, name: "Inactive User"})
      {:ok, _} = Accounts.admin_update_user(inactive, %{active: false}, actor: admin)

      conn = post(conn, ~p"/admin/masquerade/#{inactive.id}")

      assert redirected_to(conn) == ~p"/admin/users"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "inactive"
    end

    test "cannot masquerade as oneself", %{conn: conn, admin: admin} do
      conn = post(conn, ~p"/admin/masquerade/#{admin.id}")

      assert redirected_to(conn) == ~p"/admin/users"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "already logged in"
    end

    test "non-admin cannot initiate masquerade", %{conn: conn, viewer: viewer} do
      regular_conn =
        conn
        |> recycle()
        |> log_in_user(viewer)

      target = AccountsFixtures.user_fixture(%{role: :editor})

      conn = post(regular_conn, ~p"/admin/masquerade/#{target.id}")
      assert redirected_to(conn) == ~p"/domains"
    end
  end

  describe "POST /admin/unmasquerade" do
    test "restores original admin session without requiring credentials", %{
      conn: conn,
      admin: admin,
      viewer: viewer
    } do
      # 1. Masquerade
      conn = post(conn, ~p"/admin/masquerade/#{viewer.id}")
      assert redirected_to(conn) == ~p"/dashboard"

      # 2. Unmasquerade back to admin
      conn = post(recycle(conn), ~p"/admin/unmasquerade")

      assert redirected_to(conn) == ~p"/admin/users"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Switched back to #{admin.email}"
      assert get_session(conn, :masquerading_admin_token) == nil

      # 3. Verify admin access is fully restored
      conn = get(recycle(conn), ~p"/admin/users")
      assert html_response(conn, 200) =~ "User Management"
      refute html_response(conn, 200) =~ "masquerade-banner"
    end

    test "handles unmasquerade when not masquerading gracefully", %{conn: conn} do
      conn = post(conn, ~p"/admin/unmasquerade")

      assert redirected_to(conn) == ~p"/dashboard"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not currently masquerading"
    end

    test "supports DELETE /admin/unmasquerade", %{
      conn: conn,
      admin: admin,
      viewer: viewer
    } do
      conn = post(conn, ~p"/admin/masquerade/#{viewer.id}")
      assert redirected_to(conn) == ~p"/dashboard"

      conn = delete(recycle(conn), ~p"/admin/unmasquerade")
      assert redirected_to(conn) == ~p"/admin/users"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Switched back to #{admin.email}"
    end
  end
end
