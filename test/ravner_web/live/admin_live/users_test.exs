defmodule RavnerWeb.AdminLive.UsersTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.Accounts
  alias Ravner.AccountsFixtures

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  describe "user management live view" do
    test "lists existing users", %{conn: conn, admin: admin} do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer, name: "Alice Viewer"})

      {:ok, view, html} = live(conn, ~p"/admin/users")

      assert html =~ "User Management"
      assert has_element?(view, "#user-#{admin.id}")
      assert has_element?(view, "#user-#{viewer.id}", "Alice Viewer")
    end

    test "generates a one-time login link from the table row", %{conn: conn} do
      target_user = AccountsFixtures.user_fixture(%{role: :project_manager, name: "Bob PM"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      # Click key button for target_user
      view
      |> element("#user-#{target_user.id} button[phx-click='generate_one_time_login']")
      |> render_click()

      assert has_element?(view, "#one-time-login-modal")
      assert has_element?(view, "#one-time-login-modal", "One-Time Login Link Generated")
      assert has_element?(view, "#one-time-login-modal", target_user.email)

      input_value =
        view
        |> element("#one-time-login-url-input")
        |> render()

      assert input_value =~ "/users/log-in/one-time/"

      # Close modal
      view
      |> element("#one-time-login-modal button", "Done")
      |> render_click()

      refute has_element?(view, "#one-time-login-modal")
    end

    test "generates a one-time login link from the edit modal", %{conn: conn} do
      target_user = AccountsFixtures.user_fixture(%{role: :product_owner, name: "Carol PO"})

      {:ok, view, _html} = live(conn, ~p"/admin/users/#{target_user.id}/edit")

      assert has_element?(view, "#generate-one-time-login-btn")

      view
      |> element("#generate-one-time-login-btn")
      |> render_click()

      assert has_element?(view, "#one-time-login-modal")
      assert has_element?(view, "#one-time-login-modal", target_user.email)
    end

    test "creates a new user with scoped role and supervisor", %{conn: conn, admin: _admin} do
      supervisor = AccountsFixtures.user_fixture(%{role: :pm_supervisor, name: "Sup Dave"})

      {:ok, view, _html} = live(conn, ~p"/admin/users/new")

      email = "newpm-#{System.unique_integer([:positive])}@example.com"

      view
      |> form("#user-form", %{
        "user" => %{
          "email" => email,
          "name" => "Dave New PM",
          "role" => "project_manager",
          "supervisor_id" => to_string(supervisor.id),
          "password" => "supersecret123456",
          "password_confirmation" => "supersecret123456"
        }
      })
      |> render_submit()

      created = Accounts.get_user_by_email(email)
      assert created
      assert created.role == :project_manager
      assert created.supervisor_id == supervisor.id
    end

    test "renders quick masquerade card and searches users with autocomplete", %{conn: conn} do
      target_user = AccountsFixtures.user_fixture(%{role: :viewer, name: "Zoey UniqueName"})

      {:ok, view, html} = live(conn, ~p"/admin/users")

      assert html =~ "Masquerade Persona Switcher"
      assert has_element?(view, "#masquerade-search-input")
      assert has_element?(view, "#masquerade-user-#{target_user.id}")

      # Type in search query to trigger autocomplete
      view
      |> element("#masquerade-search-input")
      |> render_keyup(%{"value" => "Zoey"})

      assert has_element?(view, "#masquerade-matches")
      assert has_element?(view, "#masquerade-match-#{target_user.id}")
      assert has_element?(view, "#masquerade-match-btn-#{target_user.id}")

      # Clear search
      view
      |> element("button[phx-click='clear_masquerade_search']")
      |> render_click()

      refute has_element?(view, "#masquerade-matches")
    end

    test "renders identity sub-navigation and linked Person badge", %{conn: conn, admin: admin} do
      uid = System.unique_integer([:positive])
      member = AccountsFixtures.user_fixture(%{role: :editor, name: "Marcus Tech"})

      {:ok, org} =
        Ravner.Inventory.create_organization(
          %{
            name: "Platform Engineering #{uid}",
            slug: "platform-eng-#{uid}",
            type: :internal
          },
          actor: admin
        )

      {:ok, person} =
        Ravner.Inventory.create_person(
          %{
            first_name: "Marcus",
            last_name: "Tech",
            email: member.email,
            user_id: member.id,
            organization_id: org.id,
            title: "Lead Architect"
          },
          actor: admin
        )

      {:ok, view, html} = live(conn, ~p"/admin/users")

      # Sub-navigation tabs
      assert html =~ "System Users"
      assert html =~ "People (Governance)"
      assert html =~ "Invites"
      assert has_element?(view, "a[href='/admin/people']", "People (Governance)")

      # Linked Person badge
      assert has_element?(view, "#user-#{member.id} a[href='/admin/people/#{person.id}/edit']")
      assert has_element?(view, "#user-#{member.id}", "Marcus Tech")
      assert has_element?(view, "#user-#{member.id}", "(Platform Engineering #{uid})")
    end
  end
end
