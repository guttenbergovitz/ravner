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
        "#lifecycle-menu-#{domain.id} button[phx-click='set_lifecycle'][phx-value-state='deprecated']"
      )
      |> render_click()

      assert has_element?(view, "#lifecycle-menu-#{domain.id} button.bg-orange-500")
      assert Domains.get_domain!(domain.id).lifecycle_state == :deprecated
    end

    test "renders an external open link for a healthy domain", %{conn: conn} do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})

      {:ok, _metadata} =
        Domains.upsert_domain_metadata(domain.id, %{
          http_status: 200,
          final_url: "https://landing.example.com/path",
          http_scanned_at: DateTime.utc_now(),
          scanned_at: DateTime.utc_now()
        })

      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains")

      assert has_element?(
               view,
               "#domain-#{domain.id} a[href='https://landing.example.com/path'][target='_blank']"
             )
    end

    test "can include subdomains in the sidebar filters", %{conn: conn} do
      root = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})

      subdomain =
        DomainsFixtures.domain_fixture(%{
          name: "app.#{root.name}",
          type: :subdomain,
          parent_domain_id: root.id,
          lifecycle_state: :active
        })

      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains")

      refute has_element?(view, "#domain-#{subdomain.id}")

      view
      |> element("button[phx-click='toggle_filter_subdomains']")
      |> render_click()

      assert has_element?(view, "#domain-#{subdomain.id}")
    end

    test "filters by technical status alongside subdomains", %{conn: conn} do
      error_domain = DomainsFixtures.domain_fixture(%{technical_status: :error})
      reachable_domain = DomainsFixtures.domain_fixture(%{technical_status: :reachable})

      sub_error =
        DomainsFixtures.domain_fixture(%{
          name: "api.#{error_domain.name}",
          type: :subdomain,
          parent_domain_id: error_domain.id,
          technical_status: :error
        })

      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains")

      view
      |> element(
        "button[phx-click='toggle_facet'][phx-value-type='technical_status'][phx-value-id='error']"
      )
      |> render_click()

      assert has_element?(view, "#domain-#{error_domain.id}")
      refute has_element?(view, "#domain-#{reachable_domain.id}")

      view
      |> element("button[phx-click='toggle_filter_subdomains']")
      |> render_click()

      assert has_element?(view, "#domain-#{sub_error.id}")
    end

    test "updates subdomain lifecycle dot from expanded listing", %{conn: conn} do
      parent = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})

      subdomain =
        DomainsFixtures.domain_fixture(%{
          name: "app.#{parent.name}",
          type: :subdomain,
          parent_domain_id: parent.id,
          lifecycle_state: :active
        })

      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains")

      view
      |> element("#domain-#{parent.id} div[phx-click='toggle_expand']")
      |> render_click()

      view
      |> element("#lifecycle-menu-#{subdomain.id} button[phx-click='open_lifecycle_menu']")
      |> render_click()

      view
      |> element(
        "#lifecycle-menu-#{subdomain.id} button[phx-click='set_lifecycle'][phx-value-state='deprecated']"
      )
      |> render_click()

      assert has_element?(view, "#lifecycle-menu-#{subdomain.id} button.bg-orange-500")
      assert Domains.get_domain!(subdomain.id).lifecycle_state == :deprecated
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
