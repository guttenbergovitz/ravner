defmodule Ravner.DomainsTest do
  use Ravner.DataCase, async: true

  alias Ravner.Domains
  alias Ravner.DomainsFixtures

  describe "technical status" do
    test "scanner technical status does not overwrite governance lifecycle" do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :deprecated})

      assert {:ok, 1} = Domains.record_technical_status(domain, :error)

      domain = Domains.get_domain!(domain.id)
      assert domain.lifecycle_state == :deprecated
      assert domain.technical_status == :error
    end
  end

  describe "list_domains_filtered/1" do
    test "filters domains by IP address with whitespace" do
      domain1 = DomainsFixtures.domain_fixture(%{name: "with-ip.com"})
      domain2 = DomainsFixtures.domain_fixture(%{name: "without-ip.com"})

      Domains.upsert_domain_metadata(domain1.id, %{ip_v4: ["89.31.143.90"]})
      Domains.upsert_domain_metadata(domain2.id, %{ip_v4: ["1.2.3.4"]})

      result = Domains.list_domains_filtered(ip: "89.31.143.90 ")
      domain_ids = Enum.map(result.domains, & &1.id)

      assert domain1.id in domain_ids
      refute domain2.id in domain_ids
      assert result.total == 1
    end

    test "calculates facet counts correctly when filtering by IP" do
      domain1 = DomainsFixtures.domain_fixture(%{name: "with-ip.com"})
      Domains.upsert_domain_metadata(domain1.id, %{ip_v4: ["89.31.143.90"]})

      facets = Domains.get_facet_counts(ip: "89.31.143.90 ")
      assert is_map(facets)
      assert is_list(facets.lifecycle)
      assert is_list(facets.brands)
      assert is_list(facets.organizations)
      assert is_list(facets.projects)
    end
  end

  describe "list_domain_versions/1" do
    test "returns version records for lifecycle and ownership transitions" do
      actor = %{role: :admin}

      domain =
        DomainsFixtures.domain_fixture(%{name: "versioned-domain.com", lifecycle_state: :active})

      assert {:ok, _} = Domains.set_domain_lifecycle(domain, :deprecated, actor: actor)

      versions = Domains.list_domain_versions(domain.id)
      assert is_list(versions)
      assert length(versions) >= 2

      action_names = Enum.map(versions, & &1.version_action_name)
      assert :set_lifecycle in action_names
      assert :create in action_names

      latest = hd(versions)
      assert latest.version_action_name == :set_lifecycle
      assert latest.changes["lifecycle_state"] == "deprecated"
    end
  end

  describe "contacts and team integration" do
    alias Ravner.Inventory

    setup do
      admin = %Ravner.Accounts.User{id: 1, role: :admin, email: "admin@example.com"}
      viewer = %Ravner.Accounts.User{id: 2, role: :viewer, email: "viewer@example.com"}

      {:ok, brand} =
        Inventory.create_brand(
          %{
            name: "Contacts Brand #{System.unique_integer([:positive])}",
            slug: "contacts-brand-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "Contacts Org #{System.unique_integer([:positive])}",
            slug: "contacts-org-#{System.unique_integer([:positive])}",
            type: :internal,
            brand_id: brand.id
          },
          actor: admin
        )

      {:ok, project} =
        Inventory.create_project(
          %{
            name: "Contacts Project #{System.unique_integer([:positive])}",
            slug: "contacts-prj-#{System.unique_integer([:positive])}",
            organization_id: org.id
          },
          actor: admin
        )

      {:ok, pm_person} =
        Inventory.create_person(
          %{
            first_name: "Alice",
            last_name: "PM",
            email: "alice.pm-#{System.unique_integer([:positive])}@example.com",
            organization_id: org.id
          },
          actor: admin
        )

      {:ok, po_person} =
        Inventory.create_person(
          %{
            first_name: "Bob",
            last_name: "PO",
            email: "bob.po-#{System.unique_integer([:positive])}@example.com",
            organization_id: org.id
          },
          actor: admin
        )

      {:ok, _role1} =
        Inventory.create_project_role(
          %{
            role: "Project Manager",
            project_id: project.id,
            person_id: pm_person.id
          },
          actor: admin
        )

      {:ok, _role2} =
        Inventory.create_project_role(
          %{
            role: "Product Owner",
            project_id: project.id,
            person_id: po_person.id
          },
          actor: admin
        )

      domain =
        DomainsFixtures.domain_fixture(%{
          name: "governance-contacts-#{System.unique_integer([:positive])}.com",
          project_id: project.id,
          organization_id: org.id,
          brand_id: brand.id
        })

      {:ok,
       admin: admin,
       viewer: viewer,
       project: project,
       pm_person: pm_person,
       po_person: po_person,
       domain: domain}
    end

    test "project_team_candidates/1 groups candidates into pm, po, and all", %{
      domain: domain,
      pm_person: pm_person,
      po_person: po_person
    } do
      candidates = Domains.project_team_candidates(domain)

      pm_ids = Enum.map(candidates.pm, & &1.id)
      po_ids = Enum.map(candidates.po, & &1.id)
      all_ids = Enum.map(candidates.all, & &1.id)

      assert pm_person.id in pm_ids
      refute po_person.id in pm_ids

      assert po_person.id in po_ids
      refute pm_person.id in po_ids

      assert pm_person.id in all_ids
      assert po_person.id in all_ids
    end

    test "find_person_by_email/1 finds person case-insensitively", %{pm_person: pm_person} do
      assert found = Domains.find_person_by_email(String.upcase(pm_person.email))
      assert found.id == pm_person.id

      assert is_nil(Domains.find_person_by_email(nil))
      assert is_nil(Domains.find_person_by_email(""))
      assert is_nil(Domains.find_person_by_email("nonexistent@example.com"))
    end

    test "assign_domain_contacts/3 updates contacts and records audit version", %{
      domain: domain,
      admin: admin,
      pm_person: pm_person,
      po_person: po_person
    } do
      assert {:ok, updated_domain} =
               Domains.assign_domain_contacts(
                 domain,
                 %{pm_email: pm_person.email, po_email: po_person.email},
                 actor: admin
               )

      assert updated_domain.pm_email == pm_person.email
      assert updated_domain.po_email == po_person.email

      versions = Domains.list_domain_versions(domain.id)
      action_names = Enum.map(versions, & &1.version_action_name)
      assert :assign_contacts in action_names

      version = Enum.find(versions, &(&1.version_action_name == :assign_contacts))
      assert version.changes["pm_email"] == pm_person.email
      assert version.changes["po_email"] == po_person.email
    end

    test "assign_domain_contacts/3 enforces policy on unauthorized actor", %{
      domain: domain,
      viewer: viewer,
      pm_person: pm_person
    } do
      assert {:error, :forbidden} =
               Domains.assign_domain_contacts(
                 domain,
                 %{pm_email: pm_person.email},
                 actor: viewer
               )
    end

    test "domain_escalation_chain/1 resolves 3-tier hierarchy with assigned managers", %{
      domain: domain,
      admin: admin,
      pm_person: pm_person,
      po_person: po_person
    } do
      # 1. Assign PM & PO to domain
      {:ok, domain} =
        Domains.assign_domain_contacts(
          domain,
          %{pm_email: pm_person.email, po_email: po_person.email},
          actor: admin
        )

      # 2. Create and assign Organization Manager
      {:ok, org_manager} =
        Inventory.create_person(
          %{
            first_name: "Oliver",
            last_name: "OrgMgr",
            email: "oliver-#{System.unique_integer([:positive])}@example.com",
            organization_id: domain.organization_id
          },
          actor: admin
        )

      org = Inventory.get_organization!(domain.organization_id)
      {:ok, _} = Inventory.assign_organization_manager(org, org_manager.id, actor: admin)

      # 3. Create and assign Brand Manager
      {:ok, brand_manager} =
        Inventory.create_person(
          %{
            first_name: "Brenda",
            last_name: "BrandMgr",
            email: "brenda-#{System.unique_integer([:positive])}@example.com"
          },
          actor: admin
        )

      brand = Inventory.get_brand!(domain.brand_id)
      {:ok, _} = Inventory.assign_brand_manager(brand, brand_manager.id, actor: admin)

      # Reload domain with full preloads
      reloaded_domain = Domains.get_domain_with_preloads!(domain.id)
      chain = Domains.domain_escalation_chain(reloaded_domain)

      # L1: Operational (Project)
      assert chain.level_1_project.pm_email == pm_person.email
      assert chain.level_1_project.pm_person.id == pm_person.id
      assert chain.level_1_project.po_email == po_person.email
      assert chain.level_1_project.po_person.id == po_person.id
      assert chain.level_1_project.project.id == domain.project_id

      # L2: Company (Organization)
      assert chain.level_2_organization.organization.id == domain.organization_id
      assert chain.level_2_organization.manager.id == org_manager.id
      assert chain.level_2_organization.manager.first_name == "Oliver"

      # L3: Executive (Brand)
      assert chain.level_3_brand.brand.id == domain.brand_id
      assert chain.level_3_brand.brand_manager.id == brand_manager.id
      assert chain.level_3_brand.brand_manager.first_name == "Brenda"
    end

    test "domain_escalation_chain/1 returns graceful nils when unassigned" do
      unassigned_domain =
        DomainsFixtures.domain_fixture(%{
          name: "unassigned-chain-#{System.unique_integer([:positive])}.com"
        })

      chain = Domains.domain_escalation_chain(unassigned_domain)

      assert is_nil(chain.level_1_project.project)
      assert is_nil(chain.level_1_project.pm_email)
      assert is_nil(chain.level_1_project.pm_person)
      assert is_nil(chain.level_1_project.po_email)
      assert is_nil(chain.level_1_project.po_person)

      assert is_nil(chain.level_2_organization.organization)
      assert is_nil(chain.level_2_organization.manager)

      assert is_nil(chain.level_3_brand.brand)
      assert is_nil(chain.level_3_brand.brand_manager)
    end

    test "domain_escalation_chain/1 inherits PM and PO from assigned project when domain contacts are blank",
         %{admin: admin} do
      {:ok, lead_pm} =
        Inventory.create_person(
          %{
            first_name: "LeadPM",
            last_name: "Person",
            email: "lead-pm-#{System.unique_integer([:positive])}@example.com"
          },
          actor: admin
        )

      {:ok, lead_po} =
        Inventory.create_person(
          %{
            first_name: "LeadPO",
            last_name: "Person",
            email: "lead-po-#{System.unique_integer([:positive])}@example.com"
          },
          actor: admin
        )

      uid = System.unique_integer([:positive])

      {:ok, org} =
        Inventory.create_organization(
          %{name: "Inherit Org #{uid}", slug: "inherit-org-#{uid}"},
          actor: admin
        )

      {:ok, project} =
        Inventory.create_project(
          %{
            name: "Inherit Proj #{uid}",
            slug: "inherit-proj-#{uid}",
            organization_id: org.id,
            project_manager_id: lead_pm.id,
            product_owner_id: lead_po.id
          },
          actor: admin
        )

      domain =
        DomainsFixtures.domain_fixture(%{
          name: "inherit-test-#{uid}.com",
          project_id: project.id,
          organization_id: org.id,
          pm_email: nil,
          po_email: nil
        })

      reloaded_domain = Domains.get_domain_with_preloads!(domain.id)
      chain = Domains.domain_escalation_chain(reloaded_domain)

      assert chain.level_1_project.pm_email == lead_pm.email
      assert chain.level_1_project.pm_person.id == lead_pm.id
      assert chain.level_1_project.pm_inherited? == true

      assert chain.level_1_project.po_email == lead_po.email
      assert chain.level_1_project.po_person.id == lead_po.id
      assert chain.level_1_project.po_inherited? == true

      # Check contact_candidates prioritizes lead_pm and lead_po
      candidates = Domains.contact_candidates(reloaded_domain)
      assert hd(candidates.pm_candidates).email == lead_pm.email
      assert hd(candidates.pm_candidates).badge == "Project PM (Lead)"
      assert hd(candidates.po_candidates).email == lead_po.email
      assert hd(candidates.po_candidates).badge == "Project PO (Lead)"
    end
  end

  describe "merge_vcs_tech_evidence/3" do
    test "merges VCS technologies into tech evidence and domain metadata" do
      domain =
        DomainsFixtures.domain_fixture(%{
          name: "vcs-domain-#{System.unique_integer([:positive])}.com"
        })

      # Pre-existing HTTP tech evidence
      {:ok, _} =
        Domains.sync_tech_evidence(domain.id, [
          %{
            "name" => "Nginx",
            "version" => "1.24.0",
            "source" => "wappalyzer:direct",
            "confidence" => 100
          }
        ])

      Domains.upsert_domain_metadata(domain.id, %{tech_stack: ["Nginx"]})

      # Merge VCS technologies
      assert {:ok, _} =
               Domains.merge_vcs_tech_evidence(
                 domain.id,
                 ["Elixir", "Phoenix", "Docker"],
                 "bitbucket"
               )

      # Verify tech evidence: both Nginx and Elixir/Phoenix/Docker exist
      domain_with_preloads = Domains.get_domain_with_preloads!(domain.id)
      tech_names = Enum.map(domain_with_preloads.tech_evidence, & &1.name)

      assert "Nginx" in tech_names
      assert "Elixir" in tech_names
      assert "Phoenix" in tech_names
      assert "Docker" in tech_names

      vcs_evidence =
        Enum.filter(domain_with_preloads.tech_evidence, &String.starts_with?(&1.source, "vcs:"))

      assert length(vcs_evidence) == 3
      assert Enum.all?(vcs_evidence, &(&1.confidence == 100))

      # Verify domain_metadata.tech_stack has merged technologies
      metadata = Domains.get_domain_metadata(domain.id)
      assert "Nginx" in metadata.tech_stack
      assert "Elixir" in metadata.tech_stack
      assert "Phoenix" in metadata.tech_stack
      assert "Docker" in metadata.tech_stack
    end

    test "preserves VCS evidence when another source is synchronized" do
      domain =
        DomainsFixtures.domain_fixture(%{
          name: "source-preservation-#{System.unique_integer([:positive])}.com"
        })

      assert {:ok, _} = Domains.merge_vcs_tech_evidence(domain.id, ["Phoenix"], "bitbucket")

      assert {:ok, _} =
               Domains.sync_tech_evidence(domain.id, [
                 %{"name" => "Nginx", "source" => "wappalyzer:direct", "confidence" => 100}
               ])

      evidence = Domains.get_domain_with_preloads!(domain.id).tech_evidence
      assert Enum.any?(evidence, &(&1.name == "Phoenix" and &1.source == "vcs:bitbucket"))
      assert Enum.any?(evidence, &(&1.name == "Nginx" and &1.source == "wappalyzer:direct"))
    end

    test "empty source sync preserves existing evidence" do
      domain =
        DomainsFixtures.domain_fixture(%{
          name: "empty-source-#{System.unique_integer([:positive])}.com"
        })

      assert {:ok, _} = Domains.merge_vcs_tech_evidence(domain.id, ["Phoenix"], "bitbucket")
      assert {:ok, _} = Domains.sync_tech_evidence(domain.id, [])

      evidence = Domains.get_domain_with_preloads!(domain.id).tech_evidence
      assert Enum.any?(evidence, &(&1.name == "Phoenix" and &1.source == "vcs:bitbucket"))
    end

    test "sync_all_vcs_tech_evidence_for_domain/1 aggregates technologies from all domain repositories" do
      admin = Ravner.AccountsFixtures.user_fixture()

      {:ok, admin} =
        admin |> Ravner.Accounts.User.role_changeset(%{role: :admin}) |> Ravner.Repo.update()

      domain =
        DomainsFixtures.domain_fixture(%{
          name: "multi-vcs-domain-#{System.unique_integer([:positive])}.com"
        })

      # Repo 1: Backend API
      {:ok, _repo1} =
        Ravner.Inventory.create_project_repository(
          %{
            domain_id: domain.id,
            url: "https://bitbucket.org/acme/api",
            provider: "bitbucket",
            kind: "api",
            technology: "Elixir, Phoenix",
            is_primary: true
          },
          actor: admin
        )

      # Repo 2: Frontend Web
      {:ok, _repo2} =
        Ravner.Inventory.create_project_repository(
          %{
            domain_id: domain.id,
            url: "https://github.com/acme/frontend",
            provider: "github",
            kind: "website",
            technology: "React, TypeScript, Tailwind CSS",
            is_primary: false
          },
          actor: admin
        )

      assert {:ok, _} = Domains.sync_all_vcs_tech_evidence_for_domain(domain.id)

      domain_with_preloads = Domains.get_domain_with_preloads!(domain.id)
      tech_names = Enum.map(domain_with_preloads.tech_evidence, & &1.name)

      assert "Elixir" in tech_names
      assert "Phoenix" in tech_names
      assert "React" in tech_names
      assert "TypeScript" in tech_names
      assert "Tailwind CSS" in tech_names

      metadata = Domains.get_domain_metadata(domain.id)
      assert "Elixir" in metadata.tech_stack
      assert "Phoenix" in metadata.tech_stack
      assert "React" in metadata.tech_stack
      assert "TypeScript" in metadata.tech_stack
      assert "Tailwind CSS" in metadata.tech_stack
    end
  end
end
