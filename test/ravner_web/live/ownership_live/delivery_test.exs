defmodule RavnerWeb.OwnershipLive.DeliveryTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.Accounts
  alias Ravner.AccountsFixtures
  alias Ravner.Repo

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin, name: "Admin Lead"})

    supervisor =
      AccountsFixtures.user_fixture(%{
        role: :pm_supervisor,
        name: "Samantha Supervisor"
      })

    pm =
      AccountsFixtures.user_fixture(%{
        role: :project_manager,
        name: "Peter PM",
        supervisor_id: supervisor.id
      })

    {:ok, conn: conn, admin: admin, supervisor: supervisor, pm: pm}
  end

  describe "delivery hierarchy live view" do
    test "admin can access delivery hierarchy and view supervisors and PMs", %{
      conn: conn,
      admin: admin,
      supervisor: _supervisor,
      pm: _pm
    } do
      conn = log_in_user(conn, admin)
      {:ok, view, html} = live(conn, ~p"/ownership/delivery")

      assert html =~ "Delivery Management"
      assert has_element?(view, "span", "Samantha Supervisor")
      assert has_element?(view, "h4", "Peter PM")
    end

    test "pm supervisor can access delivery hierarchy and see their supervised PMs", %{
      conn: conn,
      supervisor: supervisor,
      pm: _pm
    } do
      conn = log_in_user(conn, supervisor)
      {:ok, view, _html} = live(conn, ~p"/ownership/delivery")

      assert has_element?(view, "span", "Samantha Supervisor")
      assert has_element?(view, "h4", "Peter PM")
    end

    test "regular viewer without delivery role is redirected to /ownership", %{
      conn: conn
    } do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})
      conn = log_in_user(conn, viewer)

      assert {:error, {:live_redirect, %{to: "/ownership", flash: flash}}} =
               live(conn, ~p"/ownership/delivery")

      assert flash["error"] =~ "permission"
    end

    test "generating one-time login link for a supervised PM", %{
      conn: conn,
      supervisor: supervisor,
      pm: pm
    } do
      conn = log_in_user(conn, supervisor)
      {:ok, view, _html} = live(conn, ~p"/ownership/delivery")

      view
      |> element("button[phx-click='generate_one_time_login'][phx-value-user_id='#{pm.id}']")
      |> render_click()

      assert has_element?(view, "#one-time-login-modal")
      assert has_element?(view, "#one-time-login-modal", pm.email)

      input_value =
        view
        |> element("#one-time-login-url-input")
        |> render()

      assert input_value =~ "/users/log-in/one-time/"
    end

    test "admin can reassign PM supervisor", %{
      conn: conn,
      admin: admin,
      pm: pm
    } do
      new_supervisor =
        AccountsFixtures.user_fixture(%{
          role: :pm_supervisor,
          name: "New Supervisor Steve"
        })

      conn = log_in_user(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/ownership/delivery")

      view
      |> render_hook("reassign_supervisor", %{
        "pm_id" => to_string(pm.id),
        "supervisor_id" => to_string(new_supervisor.id)
      })

      reloaded_pm = Repo.get!(Accounts.User, pm.id)
      assert reloaded_pm.supervisor_id == new_supervisor.id
    end

    test "supervisor can invite a new PM under them", %{
      conn: conn,
      supervisor: supervisor
    } do
      conn = log_in_user(conn, supervisor)
      {:ok, view, _html} = live(conn, ~p"/ownership/delivery")

      # Open invite modal
      view
      |> element("#invite-delivery-btn")
      |> render_click()

      assert has_element?(view, "#invite-delivery-modal")

      new_email = "invited-pm-#{System.unique_integer([:positive])}@example.com"

      view
      |> form("#delivery-invite-form", %{
        "invite" => %{
          "email" => new_email,
          "name" => "Invited PM",
          "role" => "project_manager"
        }
      })
      |> render_submit()

      assert has_element?(view, "#generated-delivery-invite-url")

      # Check invite was created
      invites = Accounts.list_invites()
      assert Enum.any?(invites, &(&1.email == new_email && &1.role == :project_manager))
    end
  end
end
