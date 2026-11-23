defmodule RavnerWeb.OwnershipLive.PersonShowTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.Inventory

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    conn = log_in_user(conn, admin)

    uid = System.unique_integer([:positive])

    {:ok, person} =
      Inventory.create_person(
        %{
          first_name: "Elena",
          last_name: "Rostova",
          email: "elena.rostova.#{uid}@example.com",
          title: "Principal Lead"
        },
        actor: admin
      )

    {:ok, brand} =
      Inventory.create_brand(
        %{
          name: "Global Tech #{uid}",
          slug: "global-tech-#{uid}",
          brand_manager_id: person.id
        },
        actor: admin
      )

    {:ok, org} =
      Inventory.create_organization(
        %{
          name: "Acme Cloud #{uid}",
          slug: "acme-cloud-#{uid}",
          type: :internal,
          brand_id: brand.id,
          manager_id: person.id
        },
        actor: admin
      )

    {:ok, pm_project} =
      Inventory.create_project(
        %{
          name: "Delivery Engine #{uid}",
          slug: "delivery-engine-#{uid}",
          organization_id: org.id,
          project_manager_id: person.id
        },
        actor: admin
      )

    {:ok, po_project} =
      Inventory.create_project(
        %{
          name: "Client Portal #{uid}",
          slug: "client-portal-#{uid}",
          organization_id: org.id,
          product_owner_id: person.id
        },
        actor: admin
      )

    {:ok,
     conn: conn,
     admin: admin,
     person: person,
     brand: brand,
     org: org,
     pm_project: pm_project,
     po_project: po_project}
  end

  describe "PersonShow leadership and governance responsibilities" do
    test "renders leadership cards and assigned projects/brands/orgs", %{
      conn: conn,
      person: person,
      brand: brand,
      org: org,
      pm_project: pm_project,
      po_project: po_project
    } do
      {:ok, view, html} = live(conn, ~p"/ownership/people/#{person.id}")

      # Header details
      assert html =~ "Elena Rostova"
      assert html =~ "Principal Lead"
      assert html =~ "Leadership"

      # Governance section
      assert has_element?(view, "h2", "Leadership & Governance Responsibilities")

      # Delivery Lead (PM) card
      assert has_element?(view, "span", "Delivery Lead (Project Manager)")
      assert has_element?(view, "a", pm_project.name)

      # Client Lead (PO) card
      assert has_element?(view, "span", "Client Lead (Product Owner)")
      assert has_element?(view, "a", po_project.name)

      # Brand Manager card
      assert has_element?(view, "span", "Brand Manager")
      assert has_element?(view, "a", brand.name)

      # Organization Manager card
      assert has_element?(view, "span", "Organization Manager")
      assert has_element?(view, "a", org.name)

      # Technical roster section
      assert has_element?(view, "h2", "Technical Team Roster Assignments")
    end
  end
end
