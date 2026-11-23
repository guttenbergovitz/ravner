defmodule RavnerWeb.DomainLive.ShowTest do
  @moduledoc """
  Tests for the DomainLive.Show page, focusing on the lean security scan UI.
  """
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.DomainsFixtures

  describe "security scan button" do
    setup %{conn: conn} do
      domain = DomainsFixtures.domain_fixture()
      {:ok, conn: conn, domain: domain}
    end

    test "renders security posture, badges, and scan controls for admin users", %{
      conn: conn,
      domain: domain
    } do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      conn = log_in_user(conn, admin)

      {:ok, view, html} = live(conn, ~p"/domains/#{domain.id}")

      assert html =~ "Security Posture"
      assert has_element?(view, "#severity-badges")
      assert has_element?(view, "#run-security-scan")
      assert has_element?(view, "#run-breach-scan")
      refute has_element?(view, "#run-security-scan-heavy")
      assert has_element?(view, "#scan-deep-tech")
      assert has_element?(view, "button[phx-click='scan_deep_tech']")
    end

    test "visible for editor users", %{conn: conn, domain: domain} do
      editor = AccountsFixtures.user_fixture(%{role: :editor})
      conn = log_in_user(conn, editor)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "#run-security-scan")
      assert has_element?(view, "#run-breach-scan")
      refute has_element?(view, "#run-security-scan-heavy")
    end

    test "hidden for viewer users", %{conn: conn, domain: domain} do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})
      conn = log_in_user(conn, viewer)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      refute has_element?(view, "button[phx-click='run_security_scan']")
    end

    test "priority lifecycle renders with the same color as the listing", %{conn: conn} do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :priority})
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "#lifecycle-menu-show .bg-teal-600")
    end
  end

  describe "governance audit trail" do
    setup %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})
      conn = log_in_user(conn, admin)
      {:ok, conn: conn, domain: domain, admin: admin}
    end

    test "renders governance audit trail card and initial create event", %{
      conn: conn,
      domain: domain
    } do
      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}?tab=audit")

      assert has_element?(view, "#governance-audit-trail")
      assert has_element?(view, "#audit-trail-timeline")
      assert has_element?(view, "#governance-audit-trail", "Governance Audit Trail")
      assert has_element?(view, "#governance-audit-trail", "Domain Registered")
    end

    test "updates audit trail reactively when lifecycle changes", %{conn: conn, domain: domain} do
      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      view
      |> element("#lifecycle-menu-show button")
      |> render_click()

      view
      |> element("button[phx-click='set_lifecycle'][phx-value-state='deprecated']")
      |> render_click()

      view
      |> element("#tab-audit")
      |> render_click()

      assert has_element?(view, "#governance-audit-trail", "Lifecycle Transition")

      assert has_element?(
               view,
               "#governance-audit-trail",
               "Transitioned lifecycle state to Deprecated"
             )
    end
  end

  describe "domain tab navigation" do
    setup %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      domain = DomainsFixtures.domain_fixture()
      conn = log_in_user(conn, admin)
      {:ok, conn: conn, domain: domain}
    end

    test "defaults to technical overview tab", %{conn: conn, domain: domain} do
      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "#tab-technical")
      assert has_element?(view, "#tab-governance")
      assert has_element?(view, "#tab-audit")
      assert has_element?(view, "#technical-details-card")
      refute has_element?(view, "#governance-assignment-card")
      refute has_element?(view, "#governance-audit-trail")
    end

    test "switches tabs interactively via patch links", %{conn: conn, domain: domain} do
      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      # Click to switch to governance tab
      view |> element("#tab-governance") |> render_click()
      assert has_element?(view, "#governance-assignment-card")
      assert has_element?(view, "#governance-escalation-chain")
      refute has_element?(view, "#technical-details-card")

      # Click to switch to audit trail tab
      view |> element("#tab-audit") |> render_click()
      assert has_element?(view, "#governance-audit-trail")
      refute has_element?(view, "#governance-assignment-card")

      # Click back to technical tab
      view |> element("#tab-technical") |> render_click()
      assert has_element?(view, "#technical-details-card")
    end
  end

  describe "contacts and team assignment" do
    alias Ravner.Domains
    alias Ravner.Inventory

    setup %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})

      {:ok, brand} =
        Inventory.create_brand(
          %{
            name: "Contacts Live Brand #{System.unique_integer([:positive])}",
            slug: "contacts-live-brand-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "Contacts Live Org #{System.unique_integer([:positive])}",
            slug: "contacts-live-org-#{System.unique_integer([:positive])}",
            type: :internal,
            brand_id: brand.id
          },
          actor: admin
        )

      {:ok, project} =
        Inventory.create_project(
          %{
            name: "Contacts Live Prj #{System.unique_integer([:positive])}",
            slug: "contacts-live-prj-#{System.unique_integer([:positive])}",
            organization_id: org.id
          },
          actor: admin
        )

      {:ok, pm_person} =
        Inventory.create_person(
          %{
            first_name: "Charlie",
            last_name: "Manager",
            email: "charlie-#{System.unique_integer([:positive])}@example.com",
            organization_id: org.id
          },
          actor: admin
        )

      {:ok, po_person} =
        Inventory.create_person(
          %{
            first_name: "Dana",
            last_name: "Owner",
            email: "dana-#{System.unique_integer([:positive])}@example.com",
            organization_id: org.id
          },
          actor: admin
        )

      {:ok, _} =
        Inventory.create_project_role(
          %{
            role: "Project Manager",
            project_id: project.id,
            person_id: pm_person.id
          },
          actor: admin
        )

      {:ok, _} =
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
          name: "contacts-live-#{System.unique_integer([:positive])}.com",
          project_id: project.id,
          organization_id: org.id,
          brand_id: brand.id
        })

      {:ok,
       conn: conn,
       admin: admin,
       viewer: viewer,
       domain: domain,
       pm_person: pm_person,
       po_person: po_person}
    end

    test "allows admin to open modal, select team members, and save contacts", %{
      conn: conn,
      admin: admin,
      domain: domain,
      pm_person: pm_person,
      po_person: po_person
    } do
      conn = log_in_user(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}?tab=governance")

      assert has_element?(view, "#open-contacts-modal-btn")

      # Open modal
      view |> element("#open-contacts-modal-btn") |> render_click()
      assert has_element?(view, "#contacts-modal")
      assert has_element?(view, "button", "Charlie Manager")
      assert has_element?(view, "button", "Dana Owner")

      # Select team members
      view
      |> element("button[phx-click='select_pm_candidate'][phx-value-email='#{pm_person.email}']")
      |> render_click()

      view
      |> element("button[phx-click='select_po_candidate'][phx-value-email='#{po_person.email}']")
      |> render_click()

      # Submit form
      view
      |> form("#contacts-form", %{"pm_email" => pm_person.email, "po_email" => po_person.email})
      |> render_submit()

      refute has_element?(view, "#contacts-modal")
      assert has_element?(view, "#pm-contact-detail", "Charlie Manager")
      assert has_element?(view, "#po-contact-detail", "Dana Owner")

      # Check governance audit trail on audit tab has been updated
      view |> element("#tab-audit") |> render_click()
      assert has_element?(view, "#governance-audit-trail", "Contacts Assignment")

      assert has_element?(
               view,
               "#governance-audit-trail",
               "Assigned PM: #{pm_person.email}, PO: #{po_person.email}"
             )
    end

    test "viewer cannot access contact assignment", %{
      conn: conn,
      viewer: viewer,
      domain: domain
    } do
      conn = log_in_user(conn, viewer)
      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}?tab=governance")

      refute has_element?(view, "#open-contacts-modal-btn")

      assert render_click(view, "open_contacts_modal") =~ "You don&#39;t have permission"
    end

    test "renders governance escalation hierarchy with all 3 tiers", %{
      conn: conn,
      admin: admin,
      domain: domain,
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

      # 2. Assign Organization Manager
      {:ok, org_manager} =
        Inventory.create_person(
          %{
            first_name: "Fiona",
            last_name: "OrgLead",
            email: "fiona-#{System.unique_integer([:positive])}@example.com",
            organization_id: domain.organization_id
          },
          actor: admin
        )

      org = Inventory.get_organization!(domain.organization_id)
      {:ok, _} = Inventory.assign_organization_manager(org, org_manager.id, actor: admin)

      # 3. Assign Brand Manager
      {:ok, brand_manager} =
        Inventory.create_person(
          %{
            first_name: "George",
            last_name: "BrandLead",
            email: "george-#{System.unique_integer([:positive])}@example.com"
          },
          actor: admin
        )

      brand = Inventory.get_brand!(domain.brand_id)
      {:ok, _} = Inventory.assign_brand_manager(brand, brand_manager.id, actor: admin)

      conn = log_in_user(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}?tab=governance")

      assert has_element?(view, "#governance-escalation-chain")
      assert has_element?(view, "#escalation-tier-1", "L1 · Operational")

      assert has_element?(
               view,
               "#escalation-tier-1",
               "#{pm_person.first_name} #{pm_person.last_name}"
             )

      assert has_element?(
               view,
               "#escalation-tier-1",
               "#{po_person.first_name} #{po_person.last_name}"
             )

      assert has_element?(view, "#escalation-tier-2", "L2 · Company")
      assert has_element?(view, "#escalation-tier-2", "Fiona OrgLead")

      assert has_element?(view, "#escalation-tier-3", "L3 · Brand")
      assert has_element?(view, "#escalation-tier-3", "George BrandLead")
    end
  end

  describe "Domain repository linking and tech evidence enrichment" do
    alias Ravner.Inventory

    setup %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role: :admin})

      domain =
        DomainsFixtures.domain_fixture(%{
          name: "repo-domain-#{System.unique_integer([:positive])}.com"
        })

      conn = log_in_user(conn, admin)
      {:ok, conn: conn, admin: admin, domain: domain}
    end

    test "renders repository card with empty state and link button in technical overview", %{
      conn: conn,
      domain: domain
    } do
      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "#domain-repository-card")
      assert has_element?(view, "#link-domain-repo-btn")

      assert has_element?(
               view,
               "#domain-repository-card",
               "No code repository linked to this domain"
             )
    end

    test "allows linking a manual repository to the domain", %{
      conn: conn,
      domain: domain
    } do
      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      # Open modal
      view
      |> element("#link-domain-repo-btn")
      |> render_click()

      assert has_element?(view, "#link-repo-modal")

      # Switch to manual mode
      view
      |> element("button[phx-click='switch_modal_mode'][phx-value-mode='manual']")
      |> render_click()

      # Submit form
      view
      |> form("#link-repo-modal form", %{
        "manual_repo" => %{
          "url" => "https://bitbucket.org/acme/portal-frontend",
          "kind" => "website",
          "notes" => "Main portal UI"
        }
      })
      |> render_submit()

      # Modal closes and repository is displayed in card
      refute has_element?(view, "#link-repo-modal")
      assert has_element?(view, "#domain-repository-card", "portal-frontend")
      assert has_element?(view, "#domain-repository-card", "bitbucket")
      assert has_element?(view, "#domain-repository-card", "website")
    end

    test "allows unlinking a repository from the domain", %{
      conn: conn,
      domain: domain,
      admin: admin
    } do
      {:ok, repo} =
        Inventory.create_project_repository(
          %{
            domain_id: domain.id,
            url: "https://github.com/acme/portal-service",
            provider: "github",
            external_id: "portal-service",
            kind: "api",
            technology: "Elixir, Phoenix"
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "#domain-repository-card", "portal-service")
      assert has_element?(view, "#domain-repository-card", "Elixir")

      # Unlink the repo
      view
      |> element("button[phx-click='unlink_repo'][phx-value-id='#{repo.id}']")
      |> render_click()

      assert has_element?(
               view,
               "#domain-repository-card",
               "No code repository linked to this domain"
             )
    end

    test "allows 1-click linking of a project repository to the domain", %{
      conn: conn,
      admin: admin
    } do
      {:ok, brand} =
        Inventory.create_brand(
          %{
            name: "Brand #{System.unique_integer([:positive])}",
            slug: "b-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "Org #{System.unique_integer([:positive])}",
            slug: "o-#{System.unique_integer([:positive])}",
            brand_id: brand.id,
            type: :internal
          },
          actor: admin
        )

      {:ok, project} =
        Inventory.create_project(
          %{
            name: "Project #{System.unique_integer([:positive])}",
            slug: "p-#{System.unique_integer([:positive])}",
            organization_id: org.id
          },
          actor: admin
        )

      {:ok, _proj_repo1} =
        Inventory.create_project_repository(
          %{
            project_id: project.id,
            url: "https://bitbucket.org/acme/shared-service-1",
            provider: "bitbucket",
            external_id: "shared-service-1",
            kind: "api"
          },
          actor: admin
        )

      {:ok, proj_repo2} =
        Inventory.create_project_repository(
          %{
            project_id: project.id,
            url: "https://bitbucket.org/acme/shared-service-2",
            provider: "bitbucket",
            external_id: "shared-service-2",
            kind: "api"
          },
          actor: admin
        )

      domain =
        DomainsFixtures.domain_fixture(%{
          name: "project-domain-#{System.unique_integer([:positive])}.com",
          project_id: project.id
        })

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      # Domain initially inherits the first project repository
      assert has_element?(view, "#domain-repository-card", "shared-service-1")

      # Open modal via Link Repository button
      view
      |> element("#link-domain-repo-btn")
      |> render_click()

      assert has_element?(view, "#link-repo-modal")
      assert has_element?(view, "#link-repo-modal", "shared-service-1")
      assert has_element?(view, "#link-repo-modal", "shared-service-2")

      # 1-click link to the second repository
      view
      |> element("button[phx-click='link_project_repo'][phx-value-repo_id='#{proj_repo2.id}']")
      |> render_click()

      refute has_element?(view, "#link-repo-modal")
      assert has_element?(view, "#domain-repository-card", "shared-service-2")
    end

    test "supports multiple repositories per domain and allows switching the primary repository",
         %{conn: conn, domain: domain, admin: admin} do
      # Repo 1: Frontend UI (Primary)
      {:ok, repo1} =
        Inventory.create_project_repository(
          %{
            domain_id: domain.id,
            url: "https://bitbucket.org/acme/frontend-ui",
            provider: "bitbucket",
            external_id: "frontend-ui",
            kind: "website",
            is_primary: true
          },
          actor: admin
        )

      # Repo 2: Backend API (Component)
      {:ok, repo2} =
        Inventory.create_project_repository(
          %{
            domain_id: domain.id,
            url: "https://github.com/acme/backend-api",
            provider: "github",
            external_id: "backend-api",
            kind: "api",
            is_primary: false
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      # Both repositories are visible
      assert has_element?(view, "#domain-repository-card", "frontend-ui")
      assert has_element?(view, "#domain-repository-card", "backend-api")

      # Initial badges
      assert has_element?(view, "#domain-repo-row-#{repo1.id}", "Primary")
      assert has_element?(view, "#domain-repo-row-#{repo2.id}", "Component")

      # Switch primary repository to Backend API
      view
      |> element("#set-primary-repo-#{repo2.id}")
      |> render_click()

      # Verify primary switched
      assert has_element?(view, "#domain-repo-row-#{repo2.id}", "Primary")
      assert has_element?(view, "#domain-repo-row-#{repo1.id}", "Component")
    end

    test "renders repository security status badge and triggers dependency scan",
         %{conn: conn, domain: domain, admin: admin} do
      {:ok, repo} =
        Inventory.create_project_repository(
          %{
            domain_id: domain.id,
            url: "https://bitbucket.org/acme/security-check-repo",
            provider: "bitbucket",
            external_id: "security-check-repo",
            kind: "api",
            scan_status: "vulnerable",
            vulnerability_count: 3,
            critical_vuln_count: 1,
            high_vuln_count: 2
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "#domain-repo-row-#{repo.id}", "3 CVEs")
      assert has_element?(view, "#domain-repo-row-#{repo.id}", "(1 crit)")
      assert has_element?(view, "#scan-domain-repo-#{repo.id}")

      # Trigger repository scan
      view
      |> element("#scan-domain-repo-#{repo.id}")
      |> render_click()

      assert render(view) =~ "Repository scan"
    end
  end

  describe "governance PM and PO autocomplete" do
    setup %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      domain = DomainsFixtures.domain_fixture()
      {:ok, conn: log_in_user(conn, admin), admin: admin, domain: domain}
    end

    test "opens contacts modal and searches PM and PO candidates", %{conn: conn, domain: domain} do
      _pm_user =
        AccountsFixtures.user_fixture(%{
          role: :project_manager,
          name: "Patricia Manager",
          email: "patricia.pm@example.com"
        })

      _po_user =
        AccountsFixtures.user_fixture(%{
          role: :product_owner,
          name: "Paul Owner",
          email: "paul.po@example.com"
        })

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}?tab=governance")

      # Click assign PM button
      assert has_element?(view, "#assign-pm-btn")
      view |> element("#assign-pm-btn") |> render_click()

      assert has_element?(view, "#pm-email-input")
      assert has_element?(view, "#po-email-input")

      # Search PM candidate by name
      view
      |> element("#pm-email-input")
      |> render_keyup(%{"value" => "Patricia"})

      # Select candidate
      view
      |> element(
        "button[phx-click='select_pm_candidate'][phx-value-email='patricia.pm@example.com']"
      )
      |> render_click()

      # Search PO candidate by role
      view
      |> element("#po-email-input")
      |> render_keyup(%{"value" => "Owner"})

      view
      |> element("button[phx-click='select_po_candidate'][phx-value-email='paul.po@example.com']")
      |> render_click()

      # Submit contacts form
      view
      |> form("#contacts-form")
      |> render_submit(%{
        "pm_email" => "patricia.pm@example.com",
        "po_email" => "paul.po@example.com"
      })

      # Modal closed and governance shows new contacts
      refute has_element?(view, "#contacts-form")
      assert has_element?(view, "#governance-assignment-card", "patricia.pm@example.com")
      assert has_element?(view, "#governance-assignment-card", "paul.po@example.com")
    end
  end

  describe "cyber risk and executive posture" do
    test "renders cyber risk card with grade, score, and handles recalculate_risk event", %{
      conn: conn
    } do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      conn = log_in_user(conn, admin)
      domain = DomainsFixtures.domain_fixture()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Ravner.Domains.upsert_domain_metadata(domain.id, %{
        scanned_at: now,
        ssl_days_remaining: 90,
        security_headers: %{
          "strict-transport-security" => "max-age=31536000",
          "content-security-policy" => "default-src 'self'",
          "x-frame-options" => "DENY"
        },
        risk_score: 95,
        risk_grade: "A+",
        risk_deductions: %{},
        risk_drivers: []
      })

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "#cyber-risk-posture-card")
      assert has_element?(view, "#recalculate-risk-btn")
      assert has_element?(view, "#cyber-risk-posture-card", "A+")
      assert has_element?(view, "#cyber-risk-posture-card", "95")

      rendered = view |> element("#recalculate-risk-btn") |> render_click()
      assert rendered =~ "Cyber risk score recalculated"
    end

    test "renders N/A and pending posture when domain has never been scanned", %{
      conn: conn
    } do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      conn = log_in_user(conn, admin)
      domain = DomainsFixtures.domain_fixture()

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "#cyber-risk-posture-card")
      assert has_element?(view, "#cyber-risk-posture-card", "N/A")
      assert has_element?(view, "#cyber-risk-posture-card", "Pending Scans")

      rendered = view |> element("#recalculate-risk-btn") |> render_click()
      assert rendered =~ "Pending initial scans"
    end
  end

  describe "scan error handling and lifecycle gating" do
    test "handles {:error, {:dns, :no_ips}} and atom errors without crashing", %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      conn = log_in_user(conn, admin)
      domain = DomainsFixtures.domain_fixture()

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      send(view.pid, {:scan_done, :dnsx, {:error, :nxdomain}})
      assert render(view) =~ "DNS resolution failed (NXDOMAIN)"

      send(view.pid, {:scan_done, :subdomains, {:error, {:dns, :no_ips}}})
      assert render(view) =~ "No routable IP addresses found"

      send(view.pid, {:scan_done, :httpx, {:ok, %{error: :connection_error}}})
      assert render(view) =~ "Connection failed"
    end

    test "does not overwrite completed a11y scan with failed scan", %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      conn = log_in_user(conn, admin)
      domain = DomainsFixtures.domain_fixture()

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      failed_scan = %{status: "failed", error_message: "pa11y timed out"}
      send(view.pid, {:a11y_scan_completed, failed_scan})
      assert render(view) =~ "Accessibility scan failed: pa11y timed out"
    end

    test "disables discovery and security scans for non-scannable lifecycle states", %{
      conn: conn
    } do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      conn = log_in_user(conn, admin)
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :placeholder})

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "#discovery-scan-panel button[phx-click='scan_all'][disabled]")
      assert render(view) =~ "Security scanning not applicable for placeholder domains"
    end
  end
end
