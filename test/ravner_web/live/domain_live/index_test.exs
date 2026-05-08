defmodule RavnerWeb.DomainLive.IndexTest do
  use RavnerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Ravner.Accounts
  alias Ravner.AccountsFixtures
  alias Ravner.Domains
  alias Ravner.DomainsFixtures
  alias Ravner.Repo

  describe "index route" do
    test "renders directly", %{conn: conn} do
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains")

      assert has_element?(view, "#search-form")
    end

    test "updates lifecycle dot immediately after changing state", %{conn: conn} do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains")

      view
      |> element("#lifecycle-menu-#{domain.id} button[phx-click='open_lifecycle_menu']")
      |> render_click()

      view
      |> element(
        "#lifecycle-menu-#{domain.id} button[phx-click='set_lifecycle'][phx-value-state='error']"
      )
      |> render_click()

      assert has_element?(view, "#lifecycle-menu-#{domain.id} button.bg-red-500")
      assert Domains.get_domain!(domain.id).lifecycle_state == :error
    end
  end

  describe "new domain route" do
    test "renders directly without requiring prior index assigns", %{conn: conn} do
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains/new")

      assert has_element?(view, "#domain-form")
    end

    test "validates while typing in the popup form", %{conn: conn} do
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains/new")

      assert view
             |> form("#domain-form", domain: %{name: "example.com", type: "domain"})
             |> render_change()
    end
  end
end
