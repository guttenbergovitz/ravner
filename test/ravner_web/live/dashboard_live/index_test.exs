defmodule RavnerWeb.DashboardLive.IndexTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.DomainsFixtures
  alias Ravner.SecurityScans

  describe "dashboard liveview" do
    setup %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      conn = log_in_user(conn, admin)
      {:ok, conn: conn, admin: admin}
    end

    test "renders dashboard with tabs navigation", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Portfolio Dashboard"
      assert has_element?(view, "#dashboard-tab-security")
      assert has_element?(view, "button[phx-value-tab='risks']")
    end

    test "switches to security tab and displays threat posture", %{conn: conn} do
      domain = DomainsFixtures.domain_fixture(%{name: "sec-test.example.com"})

      {:ok, scan} =
        SecurityScans.create_scan(%{
          domain_id: domain.id,
          tool: "security_scan",
          status: "completed",
          target: domain.name
        })

      SecurityScans.create_findings_batch(scan.id, [
        %{
          severity: "critical",
          title: "Exposed .env configuration file",
          target: "https://sec-test.example.com/.env",
          detail: %{"cve" => "CWE-200"}
        },
        %{
          severity: "high",
          title: "Deprecated TLS 1.0 Negotiated",
          target: "sec-test.example.com:443",
          detail: %{"cve" => "CWE-326"}
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Should show high-risk security alert banner on risks tab
      assert render(view) =~ "High Risk Security Vulnerabilities Detected"

      # Click "Inspect Threats" from the alert banner
      view
      |> element("button[phx-click='select_tab'][phx-value-tab='security']", "Inspect Threats")
      |> render_click()

      content = render(view)
      assert content =~ "Portfolio Severity Distribution"
      assert content =~ "Priority Remediation: Vulnerable Domains"
      assert content =~ "sec-test.example.com"
      assert content =~ "Exposed .env configuration file"
      assert content =~ "Deprecated TLS 1.0 Negotiated"
    end

    test "renders empty state when no security vulnerabilities exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element("#dashboard-tab-security")
      |> render_click()

      content = render(view)
      assert content =~ "No active vulnerabilities detected!"
      assert content =~ "Run Bulk Security Scan"
    end
  end
end
