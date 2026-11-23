defmodule RavnerWeb.AdminLive.RepositoriesTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.Inventory

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  defp create_test_project(admin) do
    uid = System.unique_integer([:positive])

    {:ok, org} =
      Inventory.create_organization(
        %{name: "Repo Org #{uid}", slug: "repo-org-#{uid}", type: :internal},
        actor: admin
      )

    {:ok, project} =
      Inventory.create_project(
        %{name: "SecOps Core #{uid}", slug: "secops-core-#{uid}", organization_id: org.id},
        actor: admin
      )

    project
  end

  describe "/admin/repositories LiveView" do
    test "lists repositories and renders metric badges", %{conn: conn, admin: admin} do
      project = create_test_project(admin)
      uid = System.unique_integer([:positive])

      {:ok, repo1} =
        Inventory.create_project_repository(
          %{
            url: "https://bitbucket.org/acme/core-service-#{uid}",
            external_id: "core-service-#{uid}",
            provider: "bitbucket",
            kind: "api",
            project_id: project.id,
            main_language: "Elixir",
            technology: "Phoenix, Postgres",
            scan_status: "scanned",
            vulnerability_count: 0
          },
          actor: admin
        )

      {:ok, repo2} =
        Inventory.create_project_repository(
          %{
            url: "https://github.com/acme/auth-service-#{uid}",
            external_id: "auth-service-#{uid}",
            provider: "github",
            kind: "website",
            project_id: project.id,
            main_language: "TypeScript",
            technology: "React, Next.js",
            scan_status: "scanned",
            vulnerability_count: 2,
            critical_vuln_count: 1,
            high_vuln_count: 1
          },
          actor: admin
        )

      {:ok, view, html} = live(conn, ~p"/admin/repositories")

      # Page Title & Header
      assert html =~ "Repositories"
      assert has_element?(view, "#btn-link-repository-header")

      # Metric Badges
      assert has_element?(view, "#stat-total-repos")
      assert has_element?(view, "#stat-vulnerable-repos")
      assert has_element?(view, "#stat-cve-count")

      # VCS Status Widget
      assert has_element?(view, "#vcs-status-widget")
      assert has_element?(view, "#vcs-provider-card-bitbucket")
      assert has_element?(view, "#vcs-provider-card-github")
      assert has_element?(view, "#vcs-provider-card-gitlab")

      # Table rows
      assert has_element?(view, "#repo-row-#{repo1.id}")
      assert has_element?(view, "#repo-row-#{repo2.id}")
      assert has_element?(view, "#btn-sbom-repo-#{repo1.id}")
      assert has_element?(view, "#btn-sbom-repo-#{repo2.id}")
      assert render(view) =~ "core-service-#{uid}"
      assert render(view) =~ "auth-service-#{uid}"
      assert render(view) =~ "2 CVEs"
      assert render(view) =~ "Clean (0 CVEs)"
    end

    test "filters repositories by search term and provider", %{conn: conn, admin: admin} do
      project = create_test_project(admin)
      uid = System.unique_integer([:positive])

      {:ok, repo_bb} =
        Inventory.create_project_repository(
          %{
            url: "https://bitbucket.org/acme/billing-worker-#{uid}",
            external_id: "billing-worker-#{uid}",
            provider: "bitbucket",
            kind: "tool",
            project_id: project.id
          },
          actor: admin
        )

      {:ok, repo_gh} =
        Inventory.create_project_repository(
          %{
            url: "https://github.com/acme/frontend-portal-#{uid}",
            external_id: "frontend-portal-#{uid}",
            provider: "github",
            kind: "website",
            project_id: project.id
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/admin/repositories")

      # Search filter
      view
      |> form("#repository-search-form", %{query: "billing"})
      |> render_change()

      assert has_element?(view, "#repo-row-#{repo_bb.id}")
      refute has_element?(view, "#repo-row-#{repo_gh.id}")

      # Provider filter
      view
      |> element("#filter-provider-select")
      |> render_change(%{provider: "github"})

      # Clear search
      view
      |> form("#repository-search-form", %{query: ""})
      |> render_change()

      assert has_element?(view, "#repo-row-#{repo_gh.id}")
      refute has_element?(view, "#repo-row-#{repo_bb.id}")
    end

    test "deletes repository from inventory", %{conn: conn, admin: admin} do
      project = create_test_project(admin)
      uid = System.unique_integer([:positive])

      {:ok, repo} =
        Inventory.create_project_repository(
          %{
            url: "https://bitbucket.org/acme/obsolete-app-#{uid}",
            external_id: "obsolete-app-#{uid}",
            provider: "bitbucket",
            kind: "website",
            project_id: project.id
          },
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/admin/repositories")
      assert has_element?(view, "#repo-row-#{repo.id}")

      view
      |> element("#btn-delete-repo-#{repo.id}")
      |> render_click()

      refute has_element?(view, "#repo-row-#{repo.id}")
      assert render(view) =~ "Repository removed from inventory"
    end

    test "opens link repository modal and preserves form state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/repositories")

      refute has_element?(view, "#link-repo-modal")

      view
      |> element("#btn-link-repository-header")
      |> render_click()

      assert has_element?(view, "#link-repo-modal")
      assert has_element?(view, "#link-repo-dialog")

      # Switch to connect mode
      view
      |> element("button[phx-click='switch_modal_mode'][phx-value-mode='connect']")
      |> render_click()

      # Changing provider in connect form updates instructions
      assert render(view) =~ "VCS Provider"
      assert render(view) =~ "Bitbucket Cloud"

      view
      |> form("#link-repo-modal form", %{
        connect: %{provider: "github", workspace: "acme"}
      })
      |> render_change()

      assert render(view) =~ "GitHub (Personal Access Token)"
      assert render(view) =~ "acme"

      # Close modal
      view
      |> element("#link-repo-dialog button[phx-click='close_link_repo']")
      |> render_click()

      refute has_element?(view, "#link-repo-modal")
    end

    test "opens connect modal directly when clicking connect on provider card in status widget",
         %{
           conn: conn
         } do
      {:ok, view, _html} = live(conn, ~p"/admin/repositories")

      assert has_element?(view, "#vcs-status-widget")
      assert has_element?(view, "#btn-connect-github")

      view
      |> element("#btn-connect-github")
      |> render_click()

      assert has_element?(view, "#link-repo-modal")
      assert has_element?(view, "#link-repo-dialog")
      assert render(view) =~ "GitHub (Personal Access Token)"
    end

    test "displays secrets badge, opens secrets modal, and allows marking status", %{
      conn: conn,
      admin: admin
    } do
      project = create_test_project(admin)
      uid = System.unique_integer([:positive])

      {:ok, repo} =
        Inventory.create_project_repository(
          %{
            url: "https://bitbucket.org/acme/leaky-repo-#{uid}",
            external_id: "leaky-repo-#{uid}",
            provider: "bitbucket",
            kind: "api",
            project_id: project.id,
            secrets_count: 1
          },
          actor: admin
        )

      secret =
        Ravner.Repo.insert!(%Ravner.Scans.ProjectRepositorySecret{
          project_repository_id: repo.id,
          project_id: project.id,
          file_path: ".env",
          line_number: 12,
          rule_id: "aws_access_key",
          rule_name: "AWS Access Key ID",
          masked_value: "AKIA************TEST",
          fingerprint_sha256: "abc1234567890def1234567890def1234567890def1234567890def12345678",
          severity: "critical",
          status: "active"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/repositories")

      # Secret button should be present
      assert has_element?(view, "#btn-view-secrets-#{repo.id}")
      assert has_element?(view, "#stat-secrets-count")

      # Click to open secrets modal
      view
      |> element("#btn-view-secrets-#{repo.id}")
      |> render_click()

      assert has_element?(view, "#secrets-modal")
      assert has_element?(view, "#secrets-dialog")
      assert has_element?(view, "#secret-finding-#{secret.id}")
      assert render(view) =~ "AWS Access Key ID"
      assert render(view) =~ ".env:12"
      assert render(view) =~ "AKIA************TEST"

      # Mark as false positive
      view
      |> element("#btn-fp-secret-#{secret.id}")
      |> render_click()

      assert render(view) =~ "Secret marked as false_positive"
      assert render(view) =~ "false_positive"

      # Close modal
      view
      |> element("#secrets-dialog button[phx-click='close_secrets']")
      |> render_click()

      refute has_element?(view, "#secrets-modal")
    end

    test "denies access to non-editor users", %{conn: conn} do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})
      authed_conn = log_in_user(conn, viewer)

      assert {:error, {:redirect, %{to: "/domains"}}} = live(authed_conn, ~p"/admin/repositories")
    end
  end
end
