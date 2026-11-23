defmodule RavnerWeb.OwnershipLive.LandscapeTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.Inventory

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    conn = log_in_user(conn, admin)

    {:ok, brand} =
      Inventory.create_brand(
        %{
          name: "Landscape Brand #{System.unique_integer([:positive])}",
          slug: "landscape-brand-#{System.unique_integer([:positive])}"
        },
        actor: admin
      )

    {:ok, org} =
      Inventory.create_organization(
        %{
          name: "Landscape Org #{System.unique_integer([:positive])}",
          slug: "landscape-org-#{System.unique_integer([:positive])}",
          type: :internal,
          brand_id: brand.id
        },
        actor: admin
      )

    {:ok, project} =
      Inventory.create_project(
        %{
          name: "Core Platform #{System.unique_integer([:positive])}",
          slug: "core-plat-#{System.unique_integer([:positive])}",
          organization_id: org.id
        },
        actor: admin
      )

    {:ok, conn: conn, admin: admin, project: project}
  end

  test "renders Enterprise Digital Landscape catalog", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/ownership/landscape")

    assert html =~ "Enterprise Digital Landscape"
    assert has_element?(view, "#create-app-btn")
  end

  test "filters applications by type", %{conn: conn, admin: admin, project: project} do
    {:ok, _app} =
      Inventory.create_application(
        %{
          name: "Global API",
          slug: "global-api-#{System.unique_integer([:positive])}",
          app_type: "api",
          criticality: "mission_critical",
          project_id: project.id
        },
        actor: admin
      )

    {:ok, view, _html} = live(conn, ~p"/ownership/landscape")
    assert has_element?(view, "h3", "Global API")

    # Filter to storefront (should hide API)
    view
    |> element("button[phx-click='filter_type'][phx-value-type='storefront']")
    |> render_click()

    refute has_element?(view, "h3", "Global API")

    # Filter back to all
    view
    |> element("button[phx-click='filter_type'][phx-value-type='all']")
    |> render_click()

    assert has_element?(view, "h3", "Global API")
  end

  test "opens application creation modal and creates new application", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/ownership/landscape")

    view
    |> element("#create-app-btn")
    |> render_click()

    assert has_element?(view, "#create-app-form")

    view
    |> form("#create-app-form", %{
      "application" => %{
        "name" => "Brand Web Portal",
        "app_type" => "portal",
        "criticality" => "tier_1",
        "project_id" => project.id,
        "description" => "Self-service customer portal"
      }
    })
    |> render_submit()

    assert has_element?(view, "h3", "Brand Web Portal")
  end
end
