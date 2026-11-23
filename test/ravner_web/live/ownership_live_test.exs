defmodule RavnerWeb.OwnershipLiveTest do
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
          name: "Acme Brand #{System.unique_integer([:positive])}",
          slug: "acme-brand-#{System.unique_integer([:positive])}"
        },
        actor: admin
      )

    {:ok, org} =
      Inventory.create_organization(
        %{
          name: "Acme Org #{System.unique_integer([:positive])}",
          slug: "acme-org-#{System.unique_integer([:positive])}",
          type: :internal,
          brand_id: brand.id
        },
        actor: admin
      )

    {:ok, brand_mgr} =
      Inventory.create_person(
        %{
          first_name: "Beatrice",
          last_name: "BrandManager",
          email: "beatrice-#{System.unique_integer([:positive])}@example.com"
        },
        actor: admin
      )

    {:ok, org_mgr} =
      Inventory.create_person(
        %{
          first_name: "Oscar",
          last_name: "OrgManager",
          email: "oscar-#{System.unique_integer([:positive])}@example.com",
          organization_id: org.id
        },
        actor: admin
      )

    {:ok, brand} = Inventory.assign_brand_manager(brand, brand_mgr.id, actor: admin)
    {:ok, org} = Inventory.assign_organization_manager(org, org_mgr.id, actor: admin)

    {:ok,
     conn: conn, admin: admin, brand: brand, org: org, brand_mgr: brand_mgr, org_mgr: org_mgr}
  end

  test "renders brand manager in ownership index", %{
    conn: conn,
    brand: brand,
    brand_mgr: brand_mgr
  } do
    {:ok, view, _html} = live(conn, ~p"/ownership")

    assert has_element?(view, "#brand-card-#{brand.id}")

    assert has_element?(
             view,
             "#brand-card-#{brand.id}",
             "#{brand_mgr.first_name} #{brand_mgr.last_name}"
           )
  end

  test "renders brand manager in brand show page", %{
    conn: conn,
    brand: brand,
    brand_mgr: brand_mgr
  } do
    {:ok, view, _html} = live(conn, ~p"/ownership/brands/#{brand.id}")

    assert has_element?(view, "h1", brand.name)
    assert has_element?(view, "a", "Beatrice BrandManager")
    assert has_element?(view, "a[href='mailto:#{brand_mgr.email}']")
  end

  test "allows assigning, changing, and unassigning brand manager directly from brand show page",
       %{
         conn: conn,
         brand: brand,
         admin: admin
       } do
    {:ok, new_person} =
      Inventory.create_person(
        %{
          first_name: "Charlotte",
          last_name: "Chief",
          email: "charlotte-#{System.unique_integer([:positive])}@example.com"
        },
        actor: admin
      )

    {:ok, view, _html} = live(conn, ~p"/ownership/brands/#{brand.id}")

    # Open modal
    view
    |> element("#assign-brand-manager-btn")
    |> render_click()

    assert has_element?(view, "#assign-brand-manager-modal")

    # Assign new person
    view
    |> form("#assign-brand-manager-modal form", %{"manager_id" => to_string(new_person.id)})
    |> render_submit()

    assert has_element?(view, "a", "Charlotte Chief")
    assert has_element?(view, "a[href='mailto:#{new_person.email}']")

    # Unassign manager via quick unassign
    view
    |> element("button[phx-click='quick_unassign_brand_manager']")
    |> render_click()

    assert has_element?(view, "#brand-governance-card", "No Brand Manager Designated")
  end

  test "renders governance audit trail for brand", %{
    conn: conn,
    brand: brand
  } do
    {:ok, view, _html} = live(conn, ~p"/ownership/brands/#{brand.id}?tab=audit")

    assert has_element?(view, "#governance-audit-trail")
    assert has_element?(view, "#audit-trail-timeline")
    assert has_element?(view, "#governance-audit-trail", "Brand Manager Assigned")
  end

  test "renders organization manager in organization show page", %{
    conn: conn,
    org: org,
    org_mgr: org_mgr
  } do
    {:ok, view, _html} = live(conn, ~p"/ownership/organizations/#{org.id}")

    assert has_element?(view, "h1", org.name)
    assert has_element?(view, "a", "Oscar OrgManager")
    assert has_element?(view, "a[href='mailto:#{org_mgr.email}']")
  end

  test "allows assigning, changing, and unassigning organization manager directly from organization show page",
       %{
         conn: conn,
         org: org,
         admin: admin
       } do
    {:ok, new_mgr} =
      Inventory.create_person(
        %{
          first_name: "Daniel",
          last_name: "Director",
          email: "daniel-#{System.unique_integer([:positive])}@example.com"
        },
        actor: admin
      )

    {:ok, view, _html} = live(conn, ~p"/ownership/organizations/#{org.id}")

    # Open modal
    view
    |> element("#assign-company-manager-btn")
    |> render_click()

    assert has_element?(view, "#assign-company-manager-modal")

    # Assign new person
    view
    |> form("#assign-company-manager-modal form", %{"manager_id" => to_string(new_mgr.id)})
    |> render_submit()

    assert has_element?(view, "a", "Daniel Director")
    assert has_element?(view, "a[href='mailto:#{new_mgr.email}']")

    # Unassign manager
    view
    |> element("button[phx-click='quick_unassign_company_manager']")
    |> render_click()

    assert has_element?(view, "#org-governance-card", "No Company Manager Designated")
  end

  test "renders governance audit trail for organization and displays escalation hierarchy", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/ownership/organizations/#{org.id}?tab=audit")

    assert has_element?(view, "#governance-audit-trail")
    assert has_element?(view, "#audit-trail-timeline")
    assert has_element?(view, "#governance-audit-trail", "Organization Manager Assigned")
  end

  test "allows quick 1-click select from candidate cards in brand manager modal", %{
    conn: conn,
    brand: brand,
    admin: admin
  } do
    {:ok, candidate} =
      Inventory.create_person(
        %{
          first_name: "Elena",
          last_name: "Executive",
          email: "elena-#{System.unique_integer([:positive])}@example.com",
          title: "Chief Brand Officer"
        },
        actor: admin
      )

    {:ok, view, _html} = live(conn, ~p"/ownership/brands/#{brand.id}")

    # Open modal
    view
    |> element("#assign-brand-manager-btn")
    |> render_click()

    # Search for candidate
    view
    |> element("#assign-brand-manager-modal input[name='query']")
    |> render_change(%{"query" => "Elena"})

    assert has_element?(view, "#assign-brand-manager-modal", "Elena Executive")

    # 1-click select
    view
    |> element("button[phx-click='assign_brand_manager'][phx-value-manager_id='#{candidate.id}']")
    |> render_click()

    assert has_element?(view, "a", "Elena Executive")
    assert has_element?(view, "a[href='mailto:#{candidate.email}']")
  end

  test "allows quick 1-click select from candidate cards in company manager modal", %{
    conn: conn,
    org: org,
    admin: admin
  } do
    {:ok, candidate} =
      Inventory.create_person(
        %{
          first_name: "Marcus",
          last_name: "Manager",
          email: "marcus-#{System.unique_integer([:positive])}@example.com",
          title: "Managing Director"
        },
        actor: admin
      )

    {:ok, view, _html} = live(conn, ~p"/ownership/organizations/#{org.id}")

    # Open modal
    view
    |> element("#assign-company-manager-btn")
    |> render_click()

    # Search for candidate
    view
    |> element("#assign-company-manager-modal input[name='query']")
    |> render_change(%{"query" => "Marcus"})

    assert has_element?(view, "#assign-company-manager-modal", "Marcus Manager")

    # 1-click select
    view
    |> element(
      "button[phx-click='assign_company_manager'][phx-value-manager_id='#{candidate.id}']"
    )
    |> render_click()

    assert has_element?(view, "a", "Marcus Manager")
    assert has_element?(view, "a[href='mailto:#{candidate.email}']")
  end

  test "displays risk posture in brand show and organization show", %{
    conn: conn,
    brand: brand,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/ownership/brands/#{brand.id}")
    assert has_element?(view, "div", "Risk Posture")

    {:ok, org_view, _html} = live(conn, ~p"/ownership/organizations/#{org.id}")
    assert has_element?(org_view, "div", "Risk Posture")
  end

  test "displays manager warning in index and sidebar when manager is missing", %{
    conn: conn,
    admin: admin
  } do
    {:ok, unassigned_brand} =
      Inventory.create_brand(
        %{
          name: "Unassigned Brand #{System.unique_integer([:positive])}",
          slug: "unassigned-brand-#{System.unique_integer([:positive])}"
        },
        actor: admin
      )

    {:ok, view, _html} = live(conn, ~p"/ownership")

    assert has_element?(
             view,
             "#brand-card-#{unassigned_brand.id}",
             "No manager designated"
           )

    assert has_element?(view, "aside", "Brands without manager")
  end
end
