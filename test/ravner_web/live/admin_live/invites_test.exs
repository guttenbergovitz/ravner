defmodule RavnerWeb.AdminLive.InvitesTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.Inventory

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    conn = log_in_user(conn, admin)

    uid = System.unique_integer([:positive])

    {:ok, brand} =
      Inventory.create_brand(
        %{name: "Brand Invites #{uid}", slug: "brand-invites-#{uid}"},
        actor: admin
      )

    {:ok, org} =
      Inventory.create_organization(
        %{name: "Org Invites #{uid}", slug: "org-invites-#{uid}", brand_id: brand.id},
        actor: admin
      )

    {:ok, project} =
      Inventory.create_project(
        %{
          name: "Project Invites #{uid}",
          slug: "project-invites-#{uid}",
          organization_id: org.id
        },
        actor: admin
      )

    {:ok, conn: conn, admin: admin, brand: brand, org: org, project: project}
  end

  describe "AdminLive.Invites" do
    test "renders invites list and allows creating an invite with target project", %{
      conn: conn,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/admin/invites")

      assert html =~ "Invites"
      assert has_element?(view, "a", "New invite")

      # Open new invite modal
      {:ok, new_view, _html} = live(conn, ~p"/admin/invites/new")

      assert has_element?(new_view, "#invite-form")

      # Change role to project_manager so target_project_id field appears
      new_view
      |> form("#invite-form", %{
        "invite" => %{
          "role" => "project_manager"
        }
      })
      |> render_change()

      assert has_element?(new_view, "#invite_target_project_id")

      # Submit invite with role: project_manager and target_project_id
      email = "invited-pm-#{System.unique_integer([:positive])}@corp.test"

      new_view
      |> form("#invite-form", %{
        "invite" => %{
          "email" => email,
          "name" => "Scoped PM Candidate",
          "role" => "project_manager",
          "target_project_id" => to_string(project.id)
        }
      })
      |> render_submit()

      # Flash / modal with generated invite link appears
      updated_html = render(new_view)
      assert updated_html =~ "Invite Link Generated"
      assert updated_html =~ email
      assert updated_html =~ "Project: #{project.name}"
    end

    test "allows creating an invite with target brand", %{
      conn: conn,
      brand: brand
    } do
      {:ok, new_view, _html} = live(conn, ~p"/admin/invites/new")

      # Change role to brand_manager
      new_view
      |> form("#invite-form", %{
        "invite" => %{
          "role" => "brand_manager"
        }
      })
      |> render_change()

      assert has_element?(new_view, "#invite_target_brand_id")

      email = "invited-bm-#{System.unique_integer([:positive])}@corp.test"

      new_view
      |> form("#invite-form", %{
        "invite" => %{
          "email" => email,
          "name" => "Brand Manager Candidate",
          "role" => "brand_manager",
          "target_brand_id" => to_string(brand.id)
        }
      })
      |> render_submit()

      updated_html = render(new_view)
      assert updated_html =~ "Invite Link Generated"
      assert updated_html =~ email
      assert updated_html =~ "Brand: #{brand.name}"
    end
  end
end
