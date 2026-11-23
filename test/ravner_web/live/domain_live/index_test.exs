defmodule RavnerWeb.DomainLive.IndexTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.Domains
  alias Ravner.DomainsFixtures

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  describe "index route" do
    test "renders directly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")

      assert has_element?(view, "#search-form")
    end

    test "updates lifecycle dot immediately after changing state", %{conn: conn} do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})

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

    test "suggests domains and allows clicking a suggestion", %{conn: conn} do
      domain =
        DomainsFixtures.domain_fixture(%{name: "apple-test-domain.com", lifecycle_state: :active})

      {:ok, view, _html} = live(conn, ~p"/domains")

      render_change(element(view, "#search-form"), %{"search" => "apple"})

      assert has_element?(view, "button[phx-click='select_suggestion']")

      view
      |> element("button[phx-click='select_suggestion']", "apple-test-domain.com")
      |> render_click()

      assert has_element?(view, "#domain-#{domain.id}")
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

      {:ok, view, _html} = live(conn, ~p"/domains")

      refute has_element?(view, "#domain-#{subdomain.id}")

      view
      |> element("#sidebar-subdomains-toggle")
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

      {:ok, view, _html} = live(conn, ~p"/domains")

      view
      |> element(
        "button[phx-click='toggle_facet'][phx-value-type='technical_status'][phx-value-id='error']"
      )
      |> render_click()

      assert has_element?(view, "#domain-#{error_domain.id}")
      refute has_element?(view, "#domain-#{reachable_domain.id}")

      view
      |> element("#sidebar-subdomains-toggle")
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

    test "searches domains by IP address without crashing", %{conn: conn} do
      domain = DomainsFixtures.domain_fixture(%{name: "ip-searched.com"})
      {:ok, _} = Domains.upsert_domain_metadata(domain.id, %{ip_v4: ["89.31.143.90"]})

      {:ok, view, _html} = live(conn, ~p"/domains?ip=89.31.143.90+")
      assert has_element?(view, "#domain-#{domain.id}")
    end

    test "opens and confirms bulk security scan modal", %{conn: conn} do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})

      {:ok, view, _html} = live(conn, ~p"/domains")

      # Select domain using checkbox wrapper with phx-stop
      view
      |> element("span[phx-click='toggle_select'][phx-value-id='#{domain.id}'][phx-stop]")
      |> render_click()

      # Click direct "Security" bulk action button in selection bar
      view
      |> element("button[phx-click='bulk_action_confirm'][phx-value-action='security_scan']")
      |> render_click()

      # Confirm modal is visible with correct copy
      content = render(view)
      assert content =~ "Run security scan on 1 domains?"
      assert content =~ "In-process security audit (curated secret probes"

      # Cancel modal
      view
      |> element("button[phx-click='bulk_action_cancel']")
      |> render_click()

      refute render(view) =~ "Run security scan on 1 domains?"
    end

    test "handles security_scan_done info message", %{conn: conn} do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})

      {:ok, view, _html} = live(conn, ~p"/domains")

      send(view.pid, {:security_scan_done, domain.id})
      assert render(view) =~ domain.name
    end

    test "search input respects subdomains toggle and displays search badge", %{conn: conn} do
      parent = DomainsFixtures.domain_fixture(%{name: "mainportal.org", lifecycle_state: :active})

      subdomain =
        DomainsFixtures.domain_fixture(%{
          name: "checkout.mainportal.org",
          type: :subdomain,
          parent_domain_id: parent.id,
          lifecycle_state: :active
        })

      {:ok, view, _html} = live(conn, ~p"/domains")

      # Search for "checkout" without subdomains included
      view
      |> form("#search-form", %{"search" => "checkout"})
      |> render_submit()

      refute has_element?(view, "#domain-#{subdomain.id}")

      # Toggle subdomains via search bar toggle
      view
      |> element("#search-subdomains-toggle")
      |> render_click()

      assert has_element?(view, "#domain-#{subdomain.id}")
      assert render(view) =~ "+ Subdomains"
    end

    test "scan_visible with include subdomains queues scans for parent and subdomains", %{
      conn: conn
    } do
      parent = DomainsFixtures.domain_fixture(%{name: "scanvis.org", lifecycle_state: :active})

      _subdomain =
        DomainsFixtures.domain_fixture(%{
          name: "api.scanvis.org",
          type: :subdomain,
          parent_domain_id: parent.id,
          lifecycle_state: :active
        })

      {:ok, view, _html} = live(conn, ~p"/domains")

      view
      |> element("button[phx-click='toggle_include_subdomains']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='scan_visible']")
        |> render_click()

      assert html =~ "Scanning 2 domains..."
    end
  end

  describe "new domain route" do
    test "renders directly without requiring prior index assigns", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains/new")

      assert has_element?(view, "#domain-form")
    end

    test "validates while typing in the popup form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains/new")

      assert view
             |> form("#domain-form", domain: %{name: "example.com", type: "domain"})
             |> render_change()
    end
  end
end
