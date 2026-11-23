defmodule RavnerWeb.AdminLive.ApiTokensTest do
  use RavnerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ravner.Accounts
  alias Ravner.AccountsFixtures
  alias Ravner.Repo

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture()
    {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
    conn = log_in_user(conn, admin)
    {:ok, conn: conn, admin: admin}
  end

  describe "access control" do
    test "denies access to non-admin users", %{conn: conn} do
      viewer = AccountsFixtures.user_fixture()
      {:ok, viewer} = viewer |> Accounts.User.role_changeset(%{role: :viewer}) |> Repo.update()
      viewer_conn = log_in_user(conn, viewer)

      assert {:error, {:redirect, %{to: "/domains"}}} = live(viewer_conn, ~p"/admin/api-tokens")
    end

    test "allows access to admin users and renders token management table", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/api-tokens")

      assert html =~ "API Tokens"
      assert html =~ "Admin Only"
      assert has_element?(view, "#btn-generate-token")
      assert html =~ "No API tokens configured yet."
    end
  end

  describe "token lifecycle" do
    test "generates a new token, shows secret once, and updates the token table", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/api-tokens")

      # Open creation modal
      view |> element("#btn-generate-token") |> render_click()
      assert has_element?(view, "#api-token-form")

      # Submit creation form
      view
      |> form("#api-token-form", %{
        "token" => %{
          "name" => "Integration CI Runner",
          "role" => "viewer",
          "expiry_preset" => "90",
          "allowed_ips" => "192.168.1.50\n10.0.0.0/16",
          "allowed_paths" => "GET /api/v1/*"
        }
      })
      |> render_submit()

      # Secret modal should be visible with generated secret
      assert has_element?(view, "#generated-token-value")
      secret_text = view |> element("#generated-token-value") |> render()
      assert secret_text =~ "rav_live_"

      # Close secret modal
      view |> element("#btn-confirm-token-copied") |> render_click()
      refute has_element?(view, "#generated-token-value")

      # Verify token appears in table
      assert render(view) =~ "Integration CI Runner"
      assert render(view) =~ "rav_live_"
      assert render(view) =~ "Active"

      # Verify token exists in database and has hashed format
      [token] = Accounts.list_api_tokens(actor: admin)
      assert token.name == "Integration CI Runner"
      assert token.role == :viewer
      assert token.allowed_ips == ["192.168.1.50", "10.0.0.0/16"]
      assert token.allowed_paths == ["GET /api/v1/*"]
      assert String.starts_with?(token.prefix, "rav_live_")
    end

    test "revokes an active token", %{conn: conn, admin: admin} do
      {:ok, token, _raw} =
        Accounts.create_api_token(
          %{
            name: "Revocable Token",
            role: :editor,
            allowed_ips: [],
            allowed_paths: ["GET /api/v1/*"]
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/admin/api-tokens")

      assert render(view) =~ "Revocable Token"
      assert has_element?(view, "#revoke-token-#{token.id}")

      # Revoke the token
      view |> element("#revoke-token-#{token.id}") |> render_click()

      # Assert UI updates to Revoked
      refute has_element?(view, "#revoke-token-#{token.id}")
      assert render(view) =~ "Revoked"

      # Assert database state
      {:ok, updated_token} = Accounts.get_api_token(token.id, actor: admin)
      refute is_nil(updated_token.revoked_at)
    end
  end
end
