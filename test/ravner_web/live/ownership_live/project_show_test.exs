defmodule RavnerWeb.OwnershipLive.ProjectShowTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.DomainsFixtures
  alias Ravner.Inventory

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    conn = log_in_user(conn, admin)

    {:ok, brand} =
      Inventory.create_brand(
        %{
          name: "Project Brand #{System.unique_integer([:positive])}",
          slug: "proj-brand-#{System.unique_integer([:positive])}"
        },
        actor: admin
      )

    {:ok, org} =
      Inventory.create_organization(
        %{
          name: "Project Org #{System.unique_integer([:positive])}",
          slug: "proj-org-#{System.unique_integer([:positive])}",
          type: :internal,
          brand_id: brand.id
        },
        actor: admin
      )

    {:ok, project} =
      Inventory.create_project(
        %{
          name: "Phoenix Portal #{System.unique_integer([:positive])}",
          slug: "phoenix-portal-#{System.unique_integer([:positive])}",
          organization_id: org.id
        },
        actor: admin
      )

    {:ok, conn: conn, admin: admin, project: project, org: org}
  end

  describe "ProjectShow Repositories tab" do
    test "renders empty state when no repositories are linked", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/ownership/projects/#{project.id}?tab=repositories")

      assert has_element?(view, "#empty-link-repo-btn")
      assert has_element?(view, "h3", "No repositories linked")
    end

    test "opens link repository modal and allows linking a manual repository", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/ownership/projects/#{project.id}?tab=repositories")

      # Click to open modal
      view
      |> element("#open-link-repo-btn")
      |> render_click()

      assert has_element?(view, "#link-repo-modal")

      # Switch to manual tab if needed
      view
      |> element("button[phx-click='switch_modal_mode'][phx-value-mode='manual']")
      |> render_click()

      # Submit manual repo form
      view
      |> form("#link-repo-modal form", %{
        "manual_repo" => %{
          "url" => "https://bitbucket.org/acme/portal-backend",
          "kind" => "api",
          "notes" => "Core API service"
        }
      })
      |> render_submit()

      # Modal closes and repository is displayed in list
      refute has_element?(view, "#link-repo-modal")
      assert has_element?(view, "div", "portal-backend")
      assert has_element?(view, "span", "bitbucket")
      assert has_element?(view, "span", "api")
    end

    test "allows unlinking a repository", %{
      conn: conn,
      project: project,
      admin: admin
    } do
      {:ok, repo} =
        Inventory.create_project_repository(
          %{
            project_id: project.id,
            url: "https://github.com/acme/frontend-app",
            provider: "github",
            external_id: "frontend-app",
            kind: "website",
            technology: "React, TypeScript"
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/ownership/projects/#{project.id}?tab=repositories")

      assert has_element?(view, "#repo-card-#{repo.id}")
      assert has_element?(view, "#repo-card-#{repo.id}", "frontend-app")
      assert has_element?(view, "#repo-card-#{repo.id}", "React")
      assert has_element?(view, "#btn-export-project-sbom")
      assert has_element?(view, "#export-sbom-repo-#{repo.id}")

      # Unlink the repo
      view
      |> element("button[phx-click='unlink_repo'][phx-value-id='#{repo.id}']")
      |> render_click()

      refute has_element?(view, "#repo-card-#{repo.id}")
      assert has_element?(view, "h3", "No repositories linked")
    end

    test "displays domain badge for repositories attached to a domain and project-wide badge for shared repositories",
         %{conn: conn, project: project, admin: admin} do
      # 1. Direct project repo (shared across project)
      {:ok, shared_repo} =
        Inventory.create_project_repository(
          %{
            project_id: project.id,
            url: "https://bitbucket.org/acme/shared-core",
            provider: "bitbucket",
            external_id: "shared-core",
            kind: "library"
          },
          actor: admin
        )

      # 2. Domain in this project with dedicated primary repo
      domain =
        DomainsFixtures.domain_fixture(%{
          name: "subapp-#{System.unique_integer([:positive])}.example.com",
          project_id: project.id
        })

      {:ok, domain_repo} =
        Inventory.create_project_repository(
          %{
            project_id: project.id,
            domain_id: domain.id,
            url: "https://github.com/acme/subapp-frontend",
            provider: "github",
            external_id: "subapp-frontend",
            kind: "website",
            is_primary: true
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/ownership/projects/#{project.id}?tab=repositories")

      # Shared repository displays Project-wide badge
      assert has_element?(view, "#repo-card-#{shared_repo.id}", "Project-wide")

      # Domain-attached repository displays domain link with (Primary) indicator
      assert has_element?(view, "#repo-card-#{domain_repo.id}", domain.name)
      assert has_element?(view, "#repo-card-#{domain_repo.id}", "(Primary)")
    end

    test "displays vulnerability badge and opens vulnerability inspection modal",
         %{conn: conn, project: project, admin: admin} do
      {:ok, repo} =
        Inventory.create_project_repository(
          %{
            project_id: project.id,
            url: "https://bitbucket.org/acme/scan-app",
            provider: "bitbucket",
            external_id: "scan-app",
            kind: "api",
            scan_status: "vulnerable",
            vulnerability_count: 2,
            critical_vuln_count: 1,
            high_vuln_count: 1
          },
          actor: admin
        )

      # Create vulnerability records
      {:ok, _v1} =
        Ravner.Repo.insert(%Ravner.Scans.ProjectRepositoryVulnerability{
          project_repository_id: repo.id,
          ecosystem: "Hex",
          package_name: "plug",
          package_version: "1.14.0",
          cve_id: "CVE-2023-99999",
          osv_id: "GHSA-plug-test-1234",
          severity: "critical",
          summary: "Header parsing flaw",
          fixed_version: "1.14.1",
          manifest_file: "mix.lock"
        })

      {:ok, view, _html} = live(conn, ~p"/ownership/projects/#{project.id}?tab=repositories")

      # Shows vulnerable badge with counter
      assert has_element?(view, "#repo-card-#{repo.id}", "2 CVEs")
      assert has_element?(view, "#repo-card-#{repo.id}", "(1 crit)")

      # Click to view vulnerabilities in modal
      view
      |> element("button[phx-click='view_repo_vulnerabilities'][phx-value-id='#{repo.id}']")
      |> render_click()

      assert has_element?(view, "#repo-vulnerabilities-modal")
      assert has_element?(view, "#repo-vulnerabilities-modal", "CVE-2023-99999")
      assert has_element?(view, "#repo-vulnerabilities-modal", "plug")
      assert has_element?(view, "#repo-vulnerabilities-modal", "Fixed in: 1.14.1")

      # Close modal
      view
      |> element("#close-repo-vulns-modal-btn")
      |> render_click()

      refute has_element?(view, "#repo-vulnerabilities-modal")
    end
  end

  describe "ProjectShow Team tab" do
    test "renders leadership cards for PM and PO", %{
      conn: conn,
      project: project,
      admin: admin
    } do
      uid = System.unique_integer([:positive])

      {:ok, pm} =
        Inventory.create_person(
          %{first_name: "Alice", last_name: "PM", email: "alice.pm-#{uid}@example.com"},
          actor: admin
        )

      {:ok, po} =
        Inventory.create_person(
          %{first_name: "Bob", last_name: "PO", email: "bob.po-#{uid}@example.com"},
          actor: admin
        )

      {:ok, updated_project} =
        Inventory.update_project(
          project,
          %{project_manager_id: pm.id, product_owner_id: po.id},
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/ownership/projects/#{updated_project.id}?tab=team")

      assert has_element?(view, "h2", "Project Leadership")
      assert has_element?(view, "div", "Alice PM")
      assert has_element?(view, "div", "Bob PO")
      assert has_element?(view, "h2", "Technical Team Roster")
    end
  end

  describe "ProjectShow Domains tab" do
    test "renders empty domains state and allows assigning and unassigning domains", %{
      conn: conn,
      project: project,
      org: org
    } do
      domain =
        DomainsFixtures.domain_fixture(%{
          name: "test-portal-#{System.unique_integer([:positive])}.example.com",
          organization_id: org.id
        })

      {:ok, view, _html} = live(conn, ~p"/ownership/projects/#{project.id}?tab=domains")

      assert has_element?(view, "h2", "Assigned Domains")
      assert has_element?(view, "h3", "No domains assigned")
      assert has_element?(view, "#open-assign-domain-btn")

      # Open Assign Domain modal
      view |> element("#open-assign-domain-btn") |> render_click()
      assert has_element?(view, "#assign-domain-modal")
      assert has_element?(view, "div", domain.name)

      # Search domain candidate
      view
      |> form("#assign-domain-modal form", %{"query" => "test-portal"})
      |> render_change()

      assert has_element?(view, "div", domain.name)

      # Click assign domain button
      view
      |> element("button[phx-click='assign_domain'][phx-value-domain_id='#{domain.id}']")
      |> render_click()

      # Domain now appears in assigned domains list
      assert has_element?(view, "a", domain.name)
      assert has_element?(view, "span", "Inherits PM/PO")

      # Unassign domain
      view
      |> element("button[phx-click='unassign_domain'][phx-value-domain_id='#{domain.id}']")
      |> render_click()

      # Back to empty state
      assert has_element?(view, "h3", "No domains assigned")
    end
  end

  describe "Project Cyber Risk Posture header" do
    test "displays N/A and pending posture when no scans recorded", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/ownership/projects/#{project.id}")

      assert html =~ "Risk Posture"
      assert html =~ "N/A"
      assert html =~ "—"
    end

    test "displays aggregated risk score and executive grade badge when telemetry exists", %{
      conn: conn,
      project: project
    } do
      {:ok, domain} =
        Ravner.Domains.create_domain(
          %{
            name: "scanned-#{System.unique_integer([:positive])}.example.com",
            project_id: project.id,
            organization_id: project.organization_id
          },
          actor: %{role: :admin}
        )

      Ravner.Domains.upsert_domain_metadata(domain.id, %{
        ssl_days_remaining: 90,
        security_headers: %{
          "strict-transport-security" => "max-age=31536000",
          "content-security-policy" => "default-src 'self'",
          "x-frame-options" => "DENY"
        },
        open_ports: [80, 443]
      })

      {:ok, _view, html} = live(conn, ~p"/ownership/projects/#{project.id}")

      assert html =~ "Risk Posture"
      assert html =~ "100"
      assert html =~ "A+"
    end
  end

  describe "ProjectShow Digital Landscape tab" do
    test "renders empty state when project has no applications", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/ownership/projects/#{project.id}?tab=landscape")

      assert has_element?(view, "h3", "No Applications Modeled Yet")
      assert has_element?(view, "#export-archimate-btn")
    end

    test "renders applications grid and Mermaid topology when applications exist", %{
      conn: conn,
      admin: admin,
      project: project
    } do
      {:ok, host} =
        Inventory.create_hosting_environment(
          %{
            name: "AWS Frankfurt",
            slug: "aws-fra-#{System.unique_integer([:positive])}",
            provider: "aws",
            environment_tier: "production",
            region: "eu-central-1"
          },
          actor: admin
        )

      {:ok, app} =
        Inventory.create_application(
          %{
            name: "Storefront Web App",
            slug: "storefront-web-#{System.unique_integer([:positive])}",
            app_type: "storefront",
            criticality: "tier_1",
            lifecycle_state: "production",
            project_id: project.id,
            hosting_environment_id: host.id
          },
          actor: admin
        )

      {:ok, _ds} =
        Inventory.create_datastore(
          %{
            name: "Storefront Postgres",
            slug: "storefront-pg-#{System.unique_integer([:positive])}",
            store_type: "postgresql",
            role: "primary_database",
            application_id: app.id,
            hosting_environment_id: host.id
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/ownership/projects/#{project.id}?tab=landscape")

      assert has_element?(view, "h4", "Storefront Web App")
      assert has_element?(view, "#project-landscape-mermaid")
      assert has_element?(view, "#export-archimate-btn")
    end

    test "downloads ArchiMate 3.1 Exchange XML export", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.id}/export/archimate")

      assert response_content_type(conn, :xml) =~ "application/xml"
      assert response(conn, 200) =~ "<model xmlns=\"http://www.opengroup.org/xsd/archimate/3.0/\""
      assert response(conn, 200) =~ "identifier=\"model-project-#{project.id}\""
    end
  end
end
