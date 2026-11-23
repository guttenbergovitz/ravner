defmodule RavnerWeb.AdminLive.SystemStatusTest do
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

  describe "system status tools" do
    test "checks external tools including dnsx, pa11y, and lighthouse", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/settings/system")

      assert html =~ "System Status"
      assert html =~ "External Tools"

      for tool <- ~w(dnsx katana lighthouse lonkero naabu nuclei pa11y whois) do
        assert html =~ tool
      end
    end

    test "allows refreshing checks", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings/system")

      assert view |> element("button[phx-click='refresh']") |> render_click() =~ "System Status"
    end
  end
end
