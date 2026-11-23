defmodule Ravner.InventoryTest do
  use Ravner.DataCase, async: true

  alias Ravner.Inventory

  describe "inventory paper trail" do
    setup do
      admin = %Ravner.Accounts.User{id: 1, role: :admin, email: "admin@example.com"}
      {:ok, admin: admin}
    end

    test "records versions on brand creation and updates", %{admin: admin} do
      {:ok, brand} =
        Inventory.create_brand(
          %{
            name: "Brand #{System.unique_integer([:positive])}",
            slug: "brand-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      assert {:ok, updated_brand} =
               Inventory.update_brand(brand, %{display_name: "Brand Display Name"}, actor: admin)

      versions = Inventory.list_brand_versions(updated_brand.id)
      assert is_list(versions)
      assert length(versions) >= 2

      actions = Enum.map(versions, & &1.version_action_name)
      assert :update in actions
      assert :create in actions

      latest = hd(versions)
      assert latest.version_action_name == :update
      assert latest.changes["display_name"] == "Brand Display Name"
    end

    test "records versions on organization creation and updates", %{admin: admin} do
      {:ok, brand} =
        Inventory.create_brand(
          %{
            name: "Brand Org #{System.unique_integer([:positive])}",
            slug: "brand-org-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "Org #{System.unique_integer([:positive])}",
            slug: "org-#{System.unique_integer([:positive])}",
            type: :internal,
            brand_id: brand.id
          },
          actor: admin
        )

      assert {:ok, updated_org} =
               Inventory.update_organization(org, %{notes: "Audited corporate note"},
                 actor: admin
               )

      versions = Inventory.list_organization_versions(updated_org.id)
      assert is_list(versions)
      assert length(versions) >= 2

      latest = hd(versions)
      assert latest.version_action_name == :update
      assert latest.changes["notes"] == "Audited corporate note"
    end

    test "records versions on project creation and updates", %{admin: admin} do
      {:ok, brand} =
        Inventory.create_brand(
          %{
            name: "Brand Prj #{System.unique_integer([:positive])}",
            slug: "brand-prj-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "Org Prj #{System.unique_integer([:positive])}",
            slug: "org-prj-#{System.unique_integer([:positive])}",
            type: :internal,
            brand_id: brand.id
          },
          actor: admin
        )

      {:ok, project} =
        Inventory.create_project(
          %{
            name: "Project #{System.unique_integer([:positive])}",
            slug: "project-#{System.unique_integer([:positive])}",
            organization_id: org.id
          },
          actor: admin
        )

      assert {:ok, updated_project} =
               Inventory.update_project(project, %{description: "Enterprise project redesign"},
                 actor: admin
               )

      versions = Inventory.list_project_versions(updated_project.id)
      assert is_list(versions)
      assert length(versions) >= 2

      latest = hd(versions)
      assert latest.version_action_name == :update
      assert latest.changes["description"] == "Enterprise project redesign"
    end

    test "records versions when assigning a brand manager", %{admin: admin} do
      {:ok, brand} =
        Inventory.create_brand(
          %{
            name: "Brand Mgr #{System.unique_integer([:positive])}",
            slug: "brand-mgr-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      {:ok, person} =
        Inventory.create_person(
          %{
            first_name: "Eleanor",
            last_name: "Vance",
            email: "eleanor.vance-#{System.unique_integer([:positive])}@example.com"
          },
          actor: admin
        )

      assert {:ok, updated_brand} =
               Inventory.assign_brand_manager(brand, person.id, actor: admin)

      assert updated_brand.brand_manager_id == person.id

      loaded_brand = Inventory.get_brand!(updated_brand.id)
      assert loaded_brand.brand_manager.id == person.id
      assert loaded_brand.brand_manager.first_name == "Eleanor"

      versions = Inventory.list_brand_versions(updated_brand.id)
      assert is_list(versions)
      actions = Enum.map(versions, & &1.version_action_name)
      assert :assign_brand_manager in actions

      version = Enum.find(versions, &(&1.version_action_name == :assign_brand_manager))
      assert version.changes["brand_manager_id"] == person.id
    end

    test "records versions when assigning an organization manager", %{admin: admin} do
      {:ok, brand} =
        Inventory.create_brand(
          %{
            name: "Brand Org Mgr #{System.unique_integer([:positive])}",
            slug: "brand-org-mgr-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "Org Mgr #{System.unique_integer([:positive])}",
            slug: "org-mgr-#{System.unique_integer([:positive])}",
            type: :internal,
            brand_id: brand.id
          },
          actor: admin
        )

      {:ok, person} =
        Inventory.create_person(
          %{
            first_name: "Victor",
            last_name: "Stone",
            email: "victor.stone-#{System.unique_integer([:positive])}@example.com",
            organization_id: org.id
          },
          actor: admin
        )

      assert {:ok, updated_org} =
               Inventory.assign_organization_manager(org, person.id, actor: admin)

      assert updated_org.manager_id == person.id

      loaded_org = Inventory.get_organization!(updated_org.id)
      assert loaded_org.manager.id == person.id
      assert loaded_org.manager.first_name == "Victor"

      versions = Inventory.list_organization_versions(updated_org.id)
      assert is_list(versions)
      actions = Enum.map(versions, & &1.version_action_name)
      assert :assign_manager in actions

      version = Enum.find(versions, &(&1.version_action_name == :assign_manager))
      assert version.changes["manager_id"] == person.id
    end

    test "records paper trail versions for Person and ProjectRole", %{admin: admin} do
      uid = System.unique_integer([:positive])

      {:ok, org} =
        Inventory.create_organization(
          %{name: "Audit Org #{uid}", slug: "audit-org-#{uid}"},
          actor: admin
        )

      {:ok, project} =
        Inventory.create_project(
          %{name: "Audit Proj #{uid}", slug: "audit-proj-#{uid}", organization_id: org.id},
          actor: admin
        )

      {:ok, person} =
        Inventory.create_person(
          %{
            first_name: "Audit",
            last_name: "Person",
            email: "audit-person-#{uid}@example.com",
            organization_id: org.id
          },
          actor: admin
        )

      {:ok, updated_person} =
        Inventory.update_person(person, %{title: "Principal Engineer"}, actor: admin)

      person_versions = Inventory.list_person_versions(updated_person.id)
      assert length(person_versions) >= 2
      assert Enum.any?(person_versions, &(&1.version_action_name == :update))

      {:ok, role} =
        Inventory.create_project_role(
          %{project_id: project.id, person_id: person.id, role: "pm"},
          actor: admin
        )

      role_versions = Inventory.list_project_role_versions(role.id)
      assert length(role_versions) >= 1
      assert Enum.any?(role_versions, &(&1.version_action_name == :create))
    end
  end

  describe "scoped queries" do
    setup do
      admin = %Ravner.Accounts.User{id: 1, role: :admin, email: "admin@example.com"}
      {:ok, admin: admin}
    end

    test "list_projects/1 filters by scope when non-global", %{admin: admin} do
      uid = System.unique_integer([:positive])

      {:ok, org} =
        Inventory.create_organization(
          %{name: "Org #{uid}", slug: "org-#{uid}"},
          actor: admin
        )

      {:ok, proj1} =
        Inventory.create_project(
          %{name: "Proj 1 #{uid}", slug: "proj1-#{uid}", organization_id: org.id},
          actor: admin
        )

      {:ok, proj2} =
        Inventory.create_project(
          %{name: "Proj 2 #{uid}", slug: "proj2-#{uid}", organization_id: org.id},
          actor: admin
        )

      scoped = %Ravner.Accounts.Scope{
        global?: false,
        project_ids: [proj1.id]
      }

      projects = Inventory.list_projects(scope: scoped)
      project_ids = Enum.map(projects, & &1.id)
      assert proj1.id in project_ids
      refute proj2.id in project_ids

      global_scope = %Ravner.Accounts.Scope{global?: true}
      all_projects = Inventory.list_projects(scope: global_scope)
      all_ids = Enum.map(all_projects, & &1.id)
      assert proj1.id in all_ids
      assert proj2.id in all_ids
    end

    test "list_projects/1 preloads project_manager and product_owner", %{admin: admin} do
      uid = System.unique_integer([:positive])

      {:ok, pm} =
        Inventory.create_person(
          %{first_name: "PM", last_name: "Lead", email: "pm-#{uid}@example.com"},
          actor: admin
        )

      {:ok, po} =
        Inventory.create_person(
          %{first_name: "PO", last_name: "Lead", email: "po-#{uid}@example.com"},
          actor: admin
        )

      {:ok, org} =
        Inventory.create_organization(
          %{name: "Org #{uid}", slug: "org-#{uid}"},
          actor: admin
        )

      {:ok, proj} =
        Inventory.create_project(
          %{
            name: "Proj #{uid}",
            slug: "proj-#{uid}",
            organization_id: org.id,
            project_manager_id: pm.id,
            product_owner_id: po.id
          },
          actor: admin
        )

      fetched = Inventory.get_project!(proj.id)
      assert fetched.project_manager.id == pm.id
      assert fetched.product_owner.id == po.id

      [found] = Inventory.list_projects(organization_id: org.id)
      assert found.project_manager.id == pm.id
      assert found.product_owner.id == po.id
    end
  end
end
