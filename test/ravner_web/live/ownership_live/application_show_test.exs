defmodule RavnerWeb.OwnershipLive.ApplicationShowTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias Ravner.Inventory

  setup %{conn: conn} do
    admin = Ravner.AccountsFixtures.user_fixture(%{role: :admin})

    {:ok, org} =
      Inventory.create_organization(%{name: "Digital Delivery Org", slug: "digital-delivery-org"},
        actor: admin
      )

    {:ok, project} =
      Inventory.create_project(
        %{name: "Core Web Project", slug: "core-web-project", organization_id: org.id},
        actor: admin
      )

    {:ok, app} =
      Inventory.create_application(
        %{
          name: "Main Commerce Portal",
          slug: "main-commerce-portal",
          app_type: "storefront",
          criticality: "mission_critical",
          project_id: project.id,
          description: "Production customer-facing storefront"
        },
        actor: admin
      )

    authed_conn = log_in_user(conn, admin)
    %{conn: authed_conn, admin: admin, project: project, app: app}
  end

  test "renders application details, overview metrics, and tabs", %{conn: conn, app: app} do
    {:ok, _view, html} = live(conn, ~p"/ownership/applications/#{app.id}")

    assert html =~ "Main Commerce Portal"
    assert html =~ "storefront"
    assert html =~ "mission_critical"
    assert html =~ "Overview &amp; Topology"
    assert html =~ "Domains"
    assert html =~ "Datastores"
    assert html =~ "External Services"
    assert html =~ "Policy Constraints"
    assert html =~ "Audit Trail"
  end

  test "updates application metadata via modal form", %{conn: conn, app: app} do
    {:ok, view, _html} = live(conn, ~p"/ownership/applications/#{app.id}")

    view
    |> element("#btn-edit-app-metadata")
    |> render_click()

    assert has_element?(view, "#modal-edit-app-metadata")

    view
    |> form("#form-edit-app", %{
      "application" => %{
        "name" => "Main Commerce Portal Enterprise",
        "description" => "Updated enterprise commerce description"
      }
    })
    |> render_submit()

    refreshed_html = render(view)
    assert refreshed_html =~ "Main Commerce Portal Enterprise"
    assert refreshed_html =~ "Updated enterprise commerce description"
  end

  test "provisions and deletes a datastore", %{conn: conn, app: app} do
    {:ok, view, _html} = live(conn, ~p"/ownership/applications/#{app.id}?tab=datastores")

    view
    |> element("#btn-open-add-datastore")
    |> render_click()

    assert has_element?(view, "#modal-add-datastore")

    view
    |> form("#form-add-datastore", %{
      "datastore" => %{
        "name" => "Commerce PostgreSQL",
        "store_type" => "postgresql",
        "role" => "primary_database",
        "notes" => "PostgreSQL 16 cluster"
      }
    })
    |> render_submit()

    html = render(view)
    assert html =~ "Commerce PostgreSQL"
    assert html =~ "primary_database"

    # Delete datastore
    view
    |> element("button[title='Remove datastore']")
    |> render_click()

    refute render(view) =~ "Commerce PostgreSQL"
  end

  test "registers and removes architecture policy constraints", %{conn: conn, app: app} do
    {:ok, view, _html} = live(conn, ~p"/ownership/applications/#{app.id}?tab=constraints")

    view
    |> element("#btn-open-add-constraint")
    |> render_click()

    assert has_element?(view, "#modal-add-constraint")

    view
    |> form("#form-add-constraint", %{
      "architecture_constraint" => %{
        "name" => "EAA WCAG 2.1 AA Mandate",
        "category" => "accessibility",
        "rule_type" => "mandatory_compliance",
        "enforcement_level" => "blocking",
        "compliance_status" => "compliant"
      }
    })
    |> render_submit()

    html = render(view)
    assert html =~ "EAA WCAG 2.1 AA Mandate"
    assert html =~ "accessibility"
    assert html =~ "compliant"

    # Delete constraint
    view
    |> element("button[title='Delete constraint']")
    |> render_click()

    refute render(view) =~ "EAA WCAG 2.1 AA Mandate"
  end
end
