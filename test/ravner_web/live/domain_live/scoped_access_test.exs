defmodule RavnerWeb.DomainLive.ScopedAccessTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.DomainsFixtures
  alias Ravner.Inventory

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})

    # Create Brand A, Org A, Project A, Domain A
    {:ok, brand_a} =
      Inventory.create_brand(
        %{name: "Brand A", slug: "brand-a-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    {:ok, org_a} =
      Inventory.create_organization(
        %{
          name: "Org A",
          slug: "org-a-#{System.unique_integer([:positive])}",
          type: :client,
          brand_id: brand_a.id
        },
        actor: admin
      )

    {:ok, proj_a} =
      Inventory.create_project(
        %{
          name: "Project A",
          slug: "proj-a-#{System.unique_integer([:positive])}",
          organization_id: org_a.id
        },
        actor: admin
      )

    domain_a =
      DomainsFixtures.domain_fixture(%{
        name: "domain-a-#{System.unique_integer([:positive])}.com",
        brand_id: brand_a.id,
        organization_id: org_a.id,
        project_id: proj_a.id
      })

    # Create Brand B, Org B, Project B, Domain B (unrelated)
    {:ok, brand_b} =
      Inventory.create_brand(
        %{name: "Brand B", slug: "brand-b-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    {:ok, org_b} =
      Inventory.create_organization(
        %{
          name: "Org B",
          slug: "org-b-#{System.unique_integer([:positive])}",
          type: :client,
          brand_id: brand_b.id
        },
        actor: admin
      )

    {:ok, proj_b} =
      Inventory.create_project(
        %{
          name: "Project B",
          slug: "proj-b-#{System.unique_integer([:positive])}",
          organization_id: org_b.id
        },
        actor: admin
      )

    domain_b =
      DomainsFixtures.domain_fixture(%{
        name: "domain-b-#{System.unique_integer([:positive])}.com",
        brand_id: brand_b.id,
        organization_id: org_b.id,
        project_id: proj_b.id
      })

    # Create User A assigned to Org A as Company Manager
    user_a = AccountsFixtures.user_fixture(%{role: :organization_manager, name: "Manager A"})

    {:ok, person_a} =
      Inventory.create_person(
        %{
          first_name: "Manager",
          last_name: "A",
          email: user_a.email,
          user_id: user_a.id,
          organization_id: org_a.id
        },
        actor: admin
      )

    {:ok, _org_a} = Inventory.assign_organization_manager(org_a, person_a.id, actor: admin)

    {:ok,
     conn: conn,
     admin: admin,
     user_a: user_a,
     domain_a: domain_a,
     domain_b: domain_b,
     brand_a: brand_a,
     brand_b: brand_b,
     org_a: org_a,
     org_b: org_b,
     proj_a: proj_a,
     proj_b: proj_b}
  end

  describe "scoped domain listing" do
    test "scoped user only sees their own domain in the listing", %{
      conn: conn,
      user_a: user_a,
      domain_a: domain_a,
      domain_b: domain_b
    } do
      conn = log_in_user(conn, user_a)
      {:ok, view, _html} = live(conn, ~p"/domains")

      assert has_element?(view, "#domain-#{domain_a.id}")
      refute has_element?(view, "#domain-#{domain_b.id}")
    end

    test "admin sees all domains in the listing", %{
      conn: conn,
      admin: admin,
      domain_a: domain_a,
      domain_b: domain_b
    } do
      conn = log_in_user(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/domains")

      assert has_element?(view, "#domain-#{domain_a.id}")
      assert has_element?(view, "#domain-#{domain_b.id}")
    end
  end

  describe "scoped domain show isolation" do
    test "scoped user can view their assigned domain", %{
      conn: conn,
      user_a: user_a,
      domain_a: domain_a
    } do
      conn = log_in_user(conn, user_a)
      {:ok, view, html} = live(conn, ~p"/domains/#{domain_a.id}")

      assert html =~ domain_a.name
      assert has_element?(view, "h1", domain_a.name)
    end

    test "scoped user is redirected when attempting to view forbidden domain", %{
      conn: conn,
      user_a: user_a,
      domain_b: domain_b
    } do
      conn = log_in_user(conn, user_a)

      assert {:error, {:live_redirect, %{to: "/domains", flash: flash}}} =
               live(conn, ~p"/domains/#{domain_b.id}")

      assert flash["error"] =~ "permission"
    end
  end

  describe "scoped ownership show isolation" do
    test "scoped user cannot view a brand outside their scope", %{
      conn: conn,
      user_a: user_a,
      brand_b: brand_b
    } do
      conn = log_in_user(conn, user_a)

      assert {:error, {:live_redirect, %{to: "/ownership", flash: flash}}} =
               live(conn, ~p"/ownership/brands/#{brand_b.id}")

      assert flash["error"] =~ "permission"
    end

    test "scoped user cannot view an organization outside their scope", %{
      conn: conn,
      user_a: user_a,
      org_b: org_b
    } do
      conn = log_in_user(conn, user_a)

      assert {:error, {:live_redirect, %{to: "/ownership", flash: flash}}} =
               live(conn, ~p"/ownership/organizations/#{org_b.id}")

      assert flash["error"] =~ "permission"
    end

    test "scoped user cannot view a project outside their scope", %{
      conn: conn,
      user_a: user_a,
      proj_b: proj_b
    } do
      conn = log_in_user(conn, user_a)

      assert {:error, {:live_redirect, %{to: "/ownership", flash: flash}}} =
               live(conn, ~p"/ownership/projects/#{proj_b.id}")

      assert flash["error"] =~ "permission"
    end
  end
end
