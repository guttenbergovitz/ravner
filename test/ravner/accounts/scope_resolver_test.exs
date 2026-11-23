defmodule Ravner.Accounts.ScopeResolverTest do
  use Ravner.DataCase, async: true

  alias Ravner.Accounts.ScopeResolver
  alias Ravner.Accounts.User
  alias Ravner.DomainsFixtures
  alias Ravner.Inventory
  alias Ravner.Repo

  describe "global roles" do
    test "admin has full global access" do
      admin = insert_user(%{role: :admin, email: "admin-#{unique_id()}@example.com"})
      scope = ScopeResolver.resolve(admin)

      assert scope.admin? == true
      assert scope.editor? == true
      assert scope.viewer? == false
      assert scope.global? == true
      assert scope.role == :admin

      assert ScopeResolver.can_view_domain?(scope, 999_999) == true
      assert ScopeResolver.can_scan_domain?(scope, 999_999) == true
      assert ScopeResolver.can_manage_domain?(scope, 999_999) == true
      assert ScopeResolver.can_view_project?(scope, 999_999) == true
      assert ScopeResolver.can_manage_project?(scope, 999_999) == true
      assert ScopeResolver.can_view_organization?(scope, 999_999) == true
      assert ScopeResolver.can_manage_organization?(scope, 999_999) == true
      assert ScopeResolver.can_view_brand?(scope, 999_999) == true
      assert ScopeResolver.can_manage_brand?(scope, 999_999) == true

      assert ScopeResolver.can_delegate_role?(scope, :admin) == true
      assert ScopeResolver.can_delegate_role?(scope, :editor) == true
      assert ScopeResolver.can_delegate_role?(scope, :viewer) == true
      assert ScopeResolver.can_delegate_role?(scope, :brand_manager) == true
      assert ScopeResolver.can_delegate_role?(scope, :organization_manager) == true
      assert ScopeResolver.can_delegate_role?(scope, :project_manager) == true
      assert ScopeResolver.can_delegate_role?(scope, :product_owner) == true
    end

    test "editor has global access to all assets but cannot delegate roles" do
      editor = insert_user(%{role: :editor, email: "editor-#{unique_id()}@example.com"})
      scope = ScopeResolver.resolve(editor)

      assert scope.admin? == false
      assert scope.editor? == true
      assert scope.viewer? == false
      assert scope.global? == true
      assert scope.role == :editor

      assert ScopeResolver.can_view_domain?(scope, 999_999) == true
      assert ScopeResolver.can_scan_domain?(scope, 999_999) == true
      assert ScopeResolver.can_manage_domain?(scope, 999_999) == true
      assert ScopeResolver.can_view_project?(scope, 999_999) == true
      assert ScopeResolver.can_manage_project?(scope, 999_999) == true

      # Only admin manages user accounts and roles
      assert ScopeResolver.can_delegate_role?(scope, :admin) == false
      assert ScopeResolver.can_delegate_role?(scope, :editor) == false
      assert ScopeResolver.can_delegate_role?(scope, :viewer) == false
      assert ScopeResolver.can_delegate_role?(scope, :project_manager) == false
    end

    test "viewer has read-only global access and cannot scan or modify" do
      viewer = insert_user(%{role: :viewer, email: "viewer-#{unique_id()}@example.com"})
      scope = ScopeResolver.resolve(viewer)

      assert scope.admin? == false
      assert scope.editor? == false
      assert scope.viewer? == true
      assert scope.global? == true
      assert scope.role == :viewer

      assert ScopeResolver.can_view_domain?(scope, 999_999) == true
      assert ScopeResolver.can_scan_domain?(scope, 999_999) == false
      assert ScopeResolver.can_manage_domain?(scope, 999_999) == false
      assert ScopeResolver.can_view_project?(scope, 999_999) == true
      assert ScopeResolver.can_manage_project?(scope, 999_999) == false

      assert ScopeResolver.can_delegate_role?(scope, :viewer) == false
    end
  end

  describe "client hierarchy (Brand Manager ➔ Company Manager ➔ PO)" do
    test "brand manager only sees and scans their brand portfolio" do
      bm_user = insert_user(%{role: :brand_manager, email: "bm-#{unique_id()}@example.com"})
      bm_person = insert_person(%{user_id: bm_user.id, email: bm_user.email})

      # Brand 1: managed by bm_user
      brand1 = insert_brand(%{brand_manager_id: bm_person.id})
      org1 = insert_organization(%{brand_id: brand1.id})
      project1 = insert_project(%{organization_id: org1.id})

      domain1 =
        DomainsFixtures.domain_fixture(%{
          project_id: project1.id,
          brand_id: brand1.id,
          organization_id: org1.id
        })

      # Brand 2: unmanaged / other
      brand2 = insert_brand(%{})
      org2 = insert_organization(%{brand_id: brand2.id})
      project2 = insert_project(%{organization_id: org2.id})

      domain2 =
        DomainsFixtures.domain_fixture(%{
          project_id: project2.id,
          brand_id: brand2.id,
          organization_id: org2.id
        })

      scope = ScopeResolver.resolve(bm_user)

      assert scope.global? == false
      assert brand1.id in scope.brand_ids
      refute brand2.id in scope.brand_ids

      assert org1.id in scope.organization_ids
      refute org2.id in scope.organization_ids

      assert project1.id in scope.project_ids
      refute project2.id in scope.project_ids

      assert domain1.id in scope.domain_ids
      refute domain2.id in scope.domain_ids

      assert ScopeResolver.can_view_domain?(scope, domain1.id) == true
      assert ScopeResolver.can_view_domain?(scope, domain2.id) == false
      assert ScopeResolver.can_scan_domain?(scope, domain1.id) == true
      assert ScopeResolver.can_scan_domain?(scope, domain2.id) == false

      # Delegation: can delegate organization_manager for brand1, not brand2
      assert ScopeResolver.can_delegate_role?(scope, :organization_manager, %{brand_id: brand1.id}) ==
               true

      assert ScopeResolver.can_delegate_role?(scope, :organization_manager, %{brand_id: brand2.id}) ==
               false

      assert ScopeResolver.can_delegate_role?(scope, :admin) == false
      assert ScopeResolver.can_delegate_role?(scope, :editor) == false
    end

    test "company manager only sees and scans their company" do
      cm_user =
        insert_user(%{role: :organization_manager, email: "cm-#{unique_id()}@example.com"})

      cm_person = insert_person(%{user_id: cm_user.id, email: cm_user.email})

      org1 = insert_organization(%{manager_id: cm_person.id})
      project1 = insert_project(%{organization_id: org1.id})

      domain1 =
        DomainsFixtures.domain_fixture(%{project_id: project1.id, organization_id: org1.id})

      org2 = insert_organization(%{})
      project2 = insert_project(%{organization_id: org2.id})

      domain2 =
        DomainsFixtures.domain_fixture(%{project_id: project2.id, organization_id: org2.id})

      scope = ScopeResolver.resolve(cm_user)

      assert org1.id in scope.organization_ids
      refute org2.id in scope.organization_ids

      assert project1.id in scope.project_ids
      refute project2.id in scope.project_ids

      assert domain1.id in scope.domain_ids
      refute domain2.id in scope.domain_ids

      assert ScopeResolver.can_scan_domain?(scope, domain1.id) == true
      assert ScopeResolver.can_scan_domain?(scope, domain2.id) == false

      # Delegation: can delegate product_owner for org1, not org2
      assert ScopeResolver.can_delegate_role?(scope, :product_owner, %{organization_id: org1.id}) ==
               true

      assert ScopeResolver.can_delegate_role?(scope, :product_owner, %{organization_id: org2.id}) ==
               false

      assert ScopeResolver.can_delegate_role?(scope, :organization_manager) == false
    end

    test "product owner by domain contact email" do
      po_email = "po-#{unique_id()}@example.com"
      po_user = insert_user(%{role: :product_owner, email: po_email})

      domain1 = DomainsFixtures.domain_fixture(%{po_email: po_email})
      domain2 = DomainsFixtures.domain_fixture(%{po_email: "other@example.com"})

      scope = ScopeResolver.resolve(po_user)

      assert domain1.id in scope.domain_ids
      refute domain2.id in scope.domain_ids

      assert ScopeResolver.can_scan_domain?(scope, domain1.id) == true
      assert ScopeResolver.can_scan_domain?(scope, domain2.id) == false
      assert ScopeResolver.can_manage_domain?(scope, domain1.id) == true
      assert ScopeResolver.can_manage_domain?(scope, domain2.id) == false

      assert ScopeResolver.can_delegate_role?(scope, :product_owner) == false
    end
  end

  describe "delivery hierarchy (Delivery Head ➔ Supervisor ➔ Cross-Company PM)" do
    test "delivery head, supervisor, and cross-company PM" do
      # 1. Delivery Head
      head_user = insert_user(%{role: :delivery_head, email: "head-#{unique_id()}@example.com"})

      # 2. Supervisors
      sup1_user = insert_user(%{role: :pm_supervisor, email: "sup1-#{unique_id()}@example.com"})
      sup2_user = insert_user(%{role: :pm_supervisor, email: "sup2-#{unique_id()}@example.com"})

      # 3. PMs
      pm1_user =
        insert_user(%{
          role: :project_manager,
          supervisor_id: sup1_user.id,
          email: "pm1-#{unique_id()}@example.com"
        })

      pm1_person = insert_person(%{user_id: pm1_user.id, email: pm1_user.email})

      pm2_user =
        insert_user(%{
          role: :project_manager,
          supervisor_id: sup2_user.id,
          email: "pm2-#{unique_id()}@example.com"
        })

      pm2_person = insert_person(%{user_id: pm2_user.id, email: pm2_user.email})

      # 4. Cross-company projects
      # Client Org A
      org_a = insert_organization(%{type: :client})
      project_a = insert_project(%{organization_id: org_a.id})

      domain_a =
        DomainsFixtures.domain_fixture(%{project_id: project_a.id, organization_id: org_a.id})

      # Client Org B
      org_b = insert_organization(%{type: :client})
      project_b = insert_project(%{organization_id: org_b.id})

      domain_b =
        DomainsFixtures.domain_fixture(%{project_id: project_b.id, organization_id: org_b.id})

      # Assign PM 1 to Project A (cross-company assignment via ProjectRole)
      insert_project_role(%{project_id: project_a.id, person_id: pm1_person.id, role: "pm"})

      # Assign PM 2 to Project B
      insert_project_role(%{project_id: project_b.id, person_id: pm2_person.id, role: "pm"})

      # --- PM 1 Scope ---
      pm1_scope = ScopeResolver.resolve(pm1_user)
      assert project_a.id in pm1_scope.project_ids
      refute project_b.id in pm1_scope.project_ids
      assert domain_a.id in pm1_scope.domain_ids
      refute domain_b.id in pm1_scope.domain_ids
      assert ScopeResolver.can_scan_domain?(pm1_scope, domain_a.id) == true
      assert ScopeResolver.can_scan_domain?(pm1_scope, domain_b.id) == false

      # --- Supervisor 1 Scope ---
      sup1_scope = ScopeResolver.resolve(sup1_user)
      assert pm1_user.id in sup1_scope.supervised_pm_ids
      refute pm2_user.id in sup1_scope.supervised_pm_ids
      assert project_a.id in sup1_scope.project_ids
      refute project_b.id in sup1_scope.project_ids
      assert domain_a.id in sup1_scope.domain_ids
      refute domain_b.id in sup1_scope.domain_ids
      assert ScopeResolver.can_scan_domain?(sup1_scope, domain_a.id) == true
      assert ScopeResolver.can_scan_domain?(sup1_scope, domain_b.id) == false

      assert ScopeResolver.can_delegate_role?(sup1_scope, :project_manager) == true
      assert ScopeResolver.can_delegate_role?(sup1_scope, :pm_supervisor) == false

      # --- Delivery Head Scope ---
      head_scope = ScopeResolver.resolve(head_user)
      assert pm1_user.id in head_scope.supervised_pm_ids
      assert pm2_user.id in head_scope.supervised_pm_ids
      assert project_a.id in head_scope.project_ids
      assert project_b.id in head_scope.project_ids
      assert domain_a.id in head_scope.domain_ids
      assert domain_b.id in head_scope.domain_ids
      assert ScopeResolver.can_scan_domain?(head_scope, domain_a.id) == true
      assert ScopeResolver.can_scan_domain?(head_scope, domain_b.id) == true

      assert ScopeResolver.can_delegate_role?(head_scope, :pm_supervisor) == true
      assert ScopeResolver.can_delegate_role?(head_scope, :project_manager) == true
      assert ScopeResolver.can_delegate_role?(head_scope, :admin) == false
    end

    test "project leadership fields (project_manager_id & product_owner_id) grant scoped access" do
      brand = insert_brand(%{})
      org = insert_organization(%{brand_id: brand.id})

      pm_user =
        insert_user(%{role: :project_manager, email: "lead-pm-#{unique_id()}@example.com"})

      po_user = insert_user(%{role: :product_owner, email: "lead-po-#{unique_id()}@example.com"})

      pm_person = insert_person(%{user_id: pm_user.id, email: pm_user.email})
      po_person = insert_person(%{user_id: po_user.id, email: po_user.email})

      project =
        insert_project(%{
          organization_id: org.id,
          project_manager_id: pm_person.id,
          product_owner_id: po_person.id
        })

      domain = DomainsFixtures.domain_fixture(%{project_id: project.id, organization_id: org.id})

      # PM Scope
      pm_scope = ScopeResolver.resolve(pm_user)
      assert project.id in pm_scope.project_ids
      assert brand.id in pm_scope.brand_ids
      assert domain.id in pm_scope.domain_ids
      assert ScopeResolver.can_view_project?(pm_scope, project.id) == true
      assert ScopeResolver.can_manage_project?(pm_scope, project.id) == true

      # PO Scope
      po_scope = ScopeResolver.resolve(po_user)
      assert project.id in po_scope.project_ids
      assert brand.id in po_scope.brand_ids
      assert domain.id in po_scope.domain_ids
      assert ScopeResolver.can_view_project?(po_scope, project.id) == true
      assert ScopeResolver.can_manage_project?(po_scope, project.id) == true
    end

    test "supervised PM leadership projects are included in supervisor's scope" do
      sup_user =
        insert_user(%{role: :pm_supervisor, email: "sup-lead-#{unique_id()}@example.com"})

      pm_user =
        insert_user(%{
          role: :project_manager,
          email: "pm-under-sup-#{unique_id()}@example.com",
          supervisor_id: sup_user.id
        })

      pm_person = insert_person(%{user_id: pm_user.id, email: pm_user.email})
      project = insert_project(%{project_manager_id: pm_person.id})
      domain = DomainsFixtures.domain_fixture(%{project_id: project.id})

      sup_scope = ScopeResolver.resolve(sup_user)
      assert pm_user.id in sup_scope.supervised_pm_ids
      assert project.id in sup_scope.project_ids
      assert domain.id in sup_scope.domain_ids
      assert ScopeResolver.can_view_project?(sup_scope, project.id) == true
    end
  end

  # ── Helper Factories ─────────────────────────────────────────────────────────

  defp unique_id, do: System.unique_integer([:positive])

  defp insert_user(attrs) do
    email = attrs[:email] || "user-#{unique_id()}@example.com"
    role = attrs[:role] || :viewer

    %User{}
    |> Ecto.Changeset.change(%{
      email: email,
      hashed_password: "$2b$04$fakehashfakehashfakehashfake",
      confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      role: role,
      active: Map.get(attrs, :active, true),
      name: attrs[:name] || "User #{unique_id()}",
      supervisor_id: attrs[:supervisor_id]
    })
    |> Repo.insert!()
  end

  @admin_actor %User{id: 999_998, role: :admin, email: "superadmin@example.com"}

  defp insert_person(attrs) do
    id = unique_id()

    attrs =
      Map.merge(
        %{
          first_name: "First#{id}",
          last_name: "Last#{id}",
          email: "person-#{id}@example.com"
        },
        Map.new(attrs)
      )

    {:ok, person} = Inventory.create_person(attrs, actor: @admin_actor)
    person
  end

  defp insert_brand(attrs) do
    id = unique_id()

    attrs =
      Map.merge(
        %{
          name: "Brand #{id}",
          slug: "brand-#{id}"
        },
        Map.new(attrs)
      )

    {:ok, brand} = Inventory.create_brand(attrs, actor: @admin_actor)
    brand
  end

  defp insert_organization(attrs) do
    id = unique_id()

    attrs =
      Map.merge(
        %{
          name: "Org #{id}",
          slug: "org-#{id}",
          type: :internal
        },
        Map.new(attrs)
      )

    {:ok, org} = Inventory.create_organization(attrs, actor: @admin_actor)
    org
  end

  defp insert_project(attrs) do
    id = unique_id()
    org_id = attrs[:organization_id] || insert_organization(%{}).id

    attrs =
      Map.merge(
        %{
          name: "Project #{id}",
          slug: "proj-#{id}",
          organization_id: org_id
        },
        Map.new(attrs)
      )

    {:ok, project} = Inventory.create_project(attrs, actor: @admin_actor)
    project
  end

  defp insert_project_role(attrs) do
    attrs = Map.merge(%{role: "pm"}, Map.new(attrs))
    {:ok, pr} = Inventory.create_project_role(attrs, actor: @admin_actor)
    pr
  end
end
