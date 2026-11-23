defmodule RavnerWeb.AdminLive.PersonLiveTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.Inventory

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  describe "admin people governance index" do
    test "lists people and displays identity navigation tabs", %{conn: conn, admin: admin} do
      uid = System.unique_integer([:positive])

      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "CyberSec Org #{uid}",
            slug: "cybersec-org-#{uid}",
            type: :internal
          },
          actor: admin
        )

      {:ok, person1} =
        Inventory.create_person(
          %{
            first_name: "Alice",
            last_name: "Wonderland",
            email: "alice.#{uid}@example.com",
            title: "CISO",
            organization_id: org.id
          },
          actor: admin
        )

      {:ok, person2} =
        Inventory.create_person(
          %{
            first_name: "Bob",
            last_name: "Builder",
            email: "bob.#{uid}@example.com",
            title: "Staff Engineer"
          },
          actor: admin
        )

      {:ok, view, html} = live(conn, ~p"/admin/people")

      # Sub-navigation tabs
      assert html =~ "System Users"
      assert html =~ "People (Governance)"
      assert html =~ "Invites"
      assert has_element?(view, "a[href='/admin/users']", "System Users")

      # People table rows
      assert has_element?(view, "#person-#{person1.id}")
      assert has_element?(view, "#person-#{person1.id}", "Alice Wonderland")
      assert has_element?(view, "#person-#{person1.id}", "CISO")
      assert has_element?(view, "#person-#{person1.id}", "CyberSec Org #{uid}")

      assert has_element?(view, "#person-#{person2.id}")
      assert has_element?(view, "#person-#{person2.id}", "Bob Builder")
      assert has_element?(view, "#person-#{person2.id}", "Staff Engineer")
    end

    test "filters people by live search query", %{conn: conn, admin: admin} do
      uid = System.unique_integer([:positive])

      {:ok, person1} =
        Inventory.create_person(
          %{
            first_name: "Diana",
            last_name: "Prince",
            email: "diana.#{uid}@example.com",
            title: "Security Champion"
          },
          actor: admin
        )

      {:ok, person2} =
        Inventory.create_person(
          %{
            first_name: "Clark",
            last_name: "Kent",
            email: "clark.#{uid}@example.com",
            title: "Reporter"
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/admin/people")

      assert has_element?(view, "#person-#{person1.id}")
      assert has_element?(view, "#person-#{person2.id}")

      # Trigger search via form change
      view
      |> form("form[phx-change='search']", %{"q" => "Champion"})
      |> render_change()

      assert has_element?(view, "#person-#{person1.id}")
      refute has_element?(view, "#person-#{person2.id}")
    end

    test "filters people by organization dropdown", %{conn: conn, admin: admin} do
      uid = System.unique_integer([:positive])

      {:ok, org1} =
        Inventory.create_organization(
          %{name: "Alpha Corp #{uid}", slug: "alpha-corp-#{uid}", type: :internal},
          actor: admin
        )

      {:ok, org2} =
        Inventory.create_organization(
          %{name: "Beta Inc #{uid}", slug: "beta-inc-#{uid}", type: :internal},
          actor: admin
        )

      {:ok, person1} =
        Inventory.create_person(
          %{
            first_name: "Natasha",
            last_name: "Romanoff",
            email: "natasha.#{uid}@example.com",
            organization_id: org1.id
          },
          actor: admin
        )

      {:ok, person2} =
        Inventory.create_person(
          %{
            first_name: "Steve",
            last_name: "Rogers",
            email: "steve.#{uid}@example.com",
            organization_id: org2.id
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/admin/people")

      # Filter by org1
      view
      |> form("form[phx-change='filter_org']", %{"org_id" => to_string(org1.id)})
      |> render_change()

      assert has_element?(view, "#person-#{person1.id}")
      refute has_element?(view, "#person-#{person2.id}")
    end

    test "displays linked user account badge and masquerade action", %{conn: conn, admin: admin} do
      uid = System.unique_integer([:positive])

      member =
        AccountsFixtures.user_fixture(%{
          role: :project_manager,
          name: "Tony Stark",
          email: "tony.#{uid}@example.com"
        })

      {:ok, person} =
        Inventory.create_person(
          %{
            first_name: "Tony",
            last_name: "Stark",
            email: member.email,
            user_id: member.id,
            title: "Chief Architect"
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/admin/people")

      assert has_element?(view, "#person-#{person.id}")
      assert has_element?(view, "#person-#{person.id}", member.email)
      assert has_element?(view, "#person-#{person.id}", "project_manager")
      assert has_element?(view, "#masquerade-person-user-#{person.id}")
    end

    test "navigates to create new person form and saves back to /admin/people", %{
      conn: conn,
      admin: admin
    } do
      uid = System.unique_integer([:positive])

      {:ok, org} =
        Inventory.create_organization(
          %{name: "Omega Tech #{uid}", slug: "omega-tech-#{uid}", type: :internal},
          actor: admin
        )

      {:ok, view, html} = live(conn, ~p"/admin/people/new")

      assert html =~ "New Person"
      assert has_element?(view, "#person-form")

      view
      |> form("#person-form", %{
        "person" => %{
          "first_name" => "Bruce",
          "last_name" => "Banner",
          "email" => "bruce.#{uid}@example.com",
          "title" => "Lead Scientist",
          "organization_id" => to_string(org.id)
        }
      })
      |> render_submit()

      {path, _flash} = assert_redirect(view)
      assert path == "/admin/people"
    end

    test "pre-fills and links user_id when navigating with query param ?user_id=...", %{
      conn: conn
    } do
      uid = System.unique_integer([:positive])

      member =
        AccountsFixtures.user_fixture(%{
          role: :editor,
          name: "Peter Parker",
          email: "peter.#{uid}@example.com"
        })

      {:ok, view, html} = live(conn, ~p"/admin/people/new?user_id=#{member.id}")

      assert html =~ "New Person"
      assert html =~ "Linked System User Account"
      assert html =~ "Peter Parker"
      assert html =~ member.email

      view
      |> form("#person-form", %{
        "person" => %{
          "first_name" => "Peter",
          "last_name" => "Parker",
          "email" => member.email,
          "title" => "Photographer",
          "user_id" => to_string(member.id)
        }
      })
      |> render_submit()

      {path, _flash} = assert_redirect(view)
      assert path == "/admin/people"

      # Verify person was linked
      created_person = Ravner.Repo.get_by(Ravner.Inventory.Person, user_id: member.id)
      assert created_person != nil
      assert created_person.first_name == "Peter"
      assert created_person.last_name == "Parker"

      {:ok, _view, html} = live(conn, ~p"/admin/people")
      assert html =~ "Peter Parker"
      assert html =~ member.email
    end
  end
end
