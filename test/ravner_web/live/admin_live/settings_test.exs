defmodule RavnerWeb.AdminLive.SettingsTest do
  use RavnerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ravner.Accounts
  alias Ravner.AccountsFixtures
  alias Ravner.Repo
  alias Ravner.ScanConfig

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture()
    {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
    conn = log_in_user(conn, admin)
    {:ok, conn: conn, admin: admin}
  end

  describe "security scan mode settings" do
    test "toggles default security scan mode between light and heavy", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/settings")

      assert html =~ "Scheduled Security Scan Mode"
      assert has_element?(view, "#set-scan-mode-light")
      assert has_element?(view, "#set-scan-mode-heavy")

      # Switch to heavy
      view |> element("#set-scan-mode-heavy") |> render_click()
      assert ScanConfig.get().security_scan_mode == "heavy"

      # Switch back to light
      view |> element("#set-scan-mode-light") |> render_click()
      assert ScanConfig.get().security_scan_mode == "light"
    end
  end

  describe "api keys known list" do
    test "renders only active keys and does not display vestigial securitytrails/shodan", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/admin/settings")

      assert html =~ "ProjectDiscovery Chaos"
      assert html =~ "Lonkero License"
      refute html =~ "SecurityTrails"
      refute html =~ "Shodan"
    end
  end

  describe "nuclei fallback tags" do
    test "toggles fallback scan categories", %{conn: conn} do
      {:ok, _} = ScanConfig.update(%{security_scanner: "nuclei", nuclei_tags: []})
      {:ok, view, html} = live(conn, ~p"/admin/settings")

      assert html =~ "Fallback Scan Categories"
      assert has_element?(view, "button[phx-click='toggle_fallback_tag'][phx-value-tag='cves']")

      view
      |> element("button[phx-click='toggle_fallback_tag'][phx-value-tag='cves']")
      |> render_click()

      assert "cves" in ScanConfig.get().nuclei_tags

      # Toggle off
      view
      |> element("button[phx-click='toggle_fallback_tag'][phx-value-tag='cves']")
      |> render_click()

      refute "cves" in ScanConfig.get().nuclei_tags
    end
  end

  describe "vcs integration card and management" do
    test "renders VCS card and allows configuring and testing Bitbucket credentials", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/admin/settings")

      assert html =~ "Version Control Systems (Bitbucket)"
      assert has_element?(view, "#vcs-integration-card")
      assert has_element?(view, "#btn-edit-vcs")

      # Click configure/edit
      view |> element("#btn-edit-vcs") |> render_click()
      assert has_element?(view, "#vcs-integration-form")

      # Submit form
      view
      |> form("#vcs-integration-form", %{
        "vcs_integration" => %{
          "workspace" => "test-workspace-corp",
          "token_type" => "workspace",
          "token" => "app-password-secret-123"
        }
      })
      |> render_submit()

      updated_html = render(view)
      assert updated_html =~ "VCS credentials saved successfully"
      assert updated_html =~ "test-workspace-corp"
      assert has_element?(view, "#btn-test-vcs")

      # Test connection (will attempt API call or return helpful auth error without crashing)
      view |> element("#btn-test-vcs") |> render_click()
      test_html = render(view)
      assert test_html =~ "Bitbucket connection"
    end

    test "editing VCS hides plaintext token and submitting empty token preserves existing secret",
         %{
           conn: conn
         } do
      {:ok, _integration} =
        Ravner.Integrations.VCS.create_integration(%{
          name: "Existing Bitbucket",
          provider: "bitbucket",
          workspace: "secret-workspace",
          token_type: "workspace",
          token: "super-secret-access-token-999",
          active: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      # Click edit
      view |> element("#btn-edit-vcs") |> render_click()

      form_html = render(view)
      # Plaintext token MUST NOT be present anywhere in the HTML
      refute form_html =~ "super-secret-access-token-999"

      # Submit form with blank token to update only the workspace
      view
      |> form("#vcs-integration-form", %{
        "vcs_integration" => %{
          "workspace" => "renamed-workspace",
          "token_type" => "workspace",
          "token" => ""
        }
      })
      |> render_submit()

      updated_html = render(view)
      assert updated_html =~ "VCS credentials saved successfully"
      assert updated_html =~ "renamed-workspace"

      # Token is still preserved in the database
      integration = hd(Ravner.Integrations.VCS.list_integrations())
      assert integration.workspace == "renamed-workspace"
      assert integration.token == "super-secret-access-token-999"
    end
  end

  describe "technology fingerprinting and threat intelligence" do
    test "renders Wappalyzer, OSV.dev and Hudson Rock intel card", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/settings")

      assert html =~ "Technology Fingerprinting &amp; Threat Intel"
      assert html =~ "OSV.dev Open Source Vulnerability DB"
      assert html =~ "Hudson Rock Cavalier Infostealer OSINT"
      assert has_element?(view, "#tech-fingerprint-card")
      assert has_element?(view, "#btn-update-wappalyzer")

      # Clicking update triggers background job dispatch
      view |> element("#btn-update-wappalyzer") |> render_click()
      assert render(view) =~ "Technology definitions update started"
    end
  end
end
