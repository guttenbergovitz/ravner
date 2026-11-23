defmodule RavnerWeb.DomainLive.SecurityReportTest do
  @moduledoc """
  Tests for the dedicated DomainLive.SecurityReport page.
  """
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.DomainsFixtures
  alias Ravner.SecurityScans

  setup %{conn: conn} do
    domain = DomainsFixtures.domain_fixture()
    user = AccountsFixtures.user_fixture(%{role: :admin})
    conn = log_in_user(conn, user)

    {:ok, conn: conn, domain: domain, user: user}
  end

  test "renders security report page with tabs and metrics", %{conn: conn, domain: domain} do
    {:ok, view, html} = live(conn, ~p"/domains/#{domain.id}/security")

    assert html =~ "Security &amp; Threat Report"
    assert html =~ domain.name
    assert has_element?(view, "#run-security-scan-btn")
    assert has_element?(view, "#run-breach-scan-btn")

    # Tabs exist
    assert has_element?(view, "button[phx-click='set_tab'][phx-value-tab='all']")
    assert has_element?(view, "button[phx-click='set_tab'][phx-value-tab='cves']")
    assert has_element?(view, "button[phx-click='set_tab'][phx-value-tab='exposures']")
    assert has_element?(view, "button[phx-click='set_tab'][phx-value-tab='tls_headers']")
    assert has_element?(view, "button[phx-click='set_tab'][phx-value-tab='ports']")
    assert has_element?(view, "button[phx-click='set_tab'][phx-value-tab='breach']")
    assert has_element?(view, "button[phx-click='set_tab'][phx-value-tab='history']")
  end

  test "displays findings and supports tab switching and searching", %{conn: conn, domain: domain} do
    {:ok, scan} =
      SecurityScans.create_scan(%{
        domain_id: domain.id,
        tool: "light_scan",
        status: "completed",
        target: domain.name,
        summary: "1 finding detected"
      })

    {:ok, finding} =
      SecurityScans.create_finding(%{
        security_scan_id: scan.id,
        severity: "critical",
        title: "Exposed Environment Configuration (.env)",
        target: "https://#{domain.name}/.env",
        detail: %{
          "source" => "curated_probes",
          "category" => "secrets",
          "description" => "Publicly accessible .env file",
          "evidence" => "DB_PASSWORD=secret"
        }
      })

    {:ok, view, html} = live(conn, ~p"/domains/#{domain.id}/security")

    assert html =~ "Exposed Environment Configuration (.env)"
    assert has_element?(view, "#finding-#{finding.id}")

    # Switch to Exposures tab
    view
    |> element("button[phx-click='set_tab'][phx-value-tab='exposures']")
    |> render_click()

    assert has_element?(view, "#finding-#{finding.id}")

    # Switch to CVEs tab (finding should not be in CVEs)
    view
    |> element("button[phx-click='set_tab'][phx-value-tab='cves']")
    |> render_click()

    refute has_element?(view, "#finding-#{finding.id}")

    # Back to all tab and test modal selection
    view
    |> element("button[phx-click='set_tab'][phx-value-tab='all']")
    |> render_click()

    view
    |> element("#finding-#{finding.id}")
    |> render_click()

    assert render(view) =~ "Publicly accessible .env file"
    assert render(view) =~ "DB_PASSWORD=secret"
  end

  test "displays dark web breach intelligence tab", %{conn: conn, domain: domain} do
    stats = %{
      heat: "hot",
      heat_label: "Hot",
      employees: 2,
      users: 10,
      stealer_families: ["RedLine", "Lumma"],
      targeted_urls: ["https://vpn.#{domain.name}"]
    }

    {:ok, _scan} =
      SecurityScans.create_scan(%{
        domain_id: domain.id,
        tool: "breach_lookup",
        status: "completed",
        target: domain.name,
        raw_output: Jason.encode!(stats),
        summary: "Hot: 2 compromised employees, 10 users"
      })

    {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}/security")

    view
    |> element("button[phx-click='set_tab'][phx-value-tab='breach']")
    |> render_click()

    html = render(view)
    assert html =~ "Dark Web Infostealer &amp; Compromised Credential Intelligence"
    assert html =~ "RedLine"
    assert html =~ "Lumma"
    assert html =~ "https://vpn.#{domain.name}"
  end

  test "triggers repository dependency scan via header button", %{conn: conn, domain: domain} do
    {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}/security")

    assert has_element?(view, "#run-repo-scan-btn")

    view
    |> element("#run-repo-scan-btn")
    |> render_click()

    assert render(view) =~ "Repository scan completed"
  end

  test "displays repository SCA vulnerabilities in CVE tab", %{conn: conn, domain: domain} do
    {:ok, scan} =
      SecurityScans.create_scan(%{
        domain_id: domain.id,
        tool: "repo_sca",
        status: "completed",
        target: "https://bitbucket.org/acme/portal-api",
        summary: "1 dependency vulnerability detected"
      })

    {:ok, finding} =
      SecurityScans.create_finding(%{
        security_scan_id: scan.id,
        severity: "critical",
        title: "CVE-2023-45853 — zlib v1.2.11 (Packagist): Minizip integer overflow",
        target: "https://bitbucket.org/acme/portal-api",
        detail: %{
          "source" => "repo_sca",
          "cve" => "CVE-2023-45853",
          "ecosystem" => "Packagist",
          "tech" => "zlib",
          "version" => "1.2.11",
          "fixed_version" => "1.3",
          "manifest_file" => "composer.lock"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}/security")

    # Switch to CVE tab
    view
    |> element("button[phx-click='set_tab'][phx-value-tab='cves']")
    |> render_click()

    assert has_element?(view, "#finding-#{finding.id}")
    assert render(view) =~ "CVE-2023-45853"
    assert render(view) =~ "Repo SCA"
  end
end
