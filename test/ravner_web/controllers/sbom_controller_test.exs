defmodule RavnerWeb.SbomControllerTest do
  use RavnerWeb.ConnCase, async: true

  alias Ravner.AccountsFixtures
  alias Ravner.Inventory
  alias Ravner.Repo
  alias Ravner.Scans.ProjectRepositoryVulnerability

  setup do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    editor = AccountsFixtures.user_fixture(%{role: :editor})
    viewer = AccountsFixtures.user_fixture(%{role: :viewer})

    suffix = System.unique_integer([:positive])

    {:ok, brand} =
      Inventory.create_brand(
        %{name: "Brand #{suffix}", slug: "brand-#{suffix}"},
        actor: admin
      )

    {:ok, org} =
      Inventory.create_organization(
        %{name: "Org #{suffix}", slug: "org-#{suffix}", type: :internal, brand_id: brand.id},
        actor: admin
      )

    {:ok, project} =
      Inventory.create_project(
        %{
          name: "Project #{suffix}",
          slug: "proj-#{suffix}",
          organization_id: org.id
        },
        actor: admin
      )

    {:ok, repo} =
      Inventory.create_project_repository(
        %{
          url: "https://bitbucket.org/testorg/sbom-test-repo-#{suffix}.git",
          external_id: "testorg/sbom-test-repo-#{suffix}",
          kind: "api",
          provider: "bitbucket",
          project_id: project.id,
          last_commit_hash: "a1b2c3d4"
        },
        actor: admin
      )

    Repo.insert!(%ProjectRepositoryVulnerability{
      project_repository_id: repo.id,
      cve_id: "CVE-2024-5555",
      osv_id: "GHSA-5555-5555-5555",
      package_name: "plug",
      package_version: "1.14.0",
      ecosystem: "Hex",
      severity: "medium",
      summary: "Header injection vulnerability",
      fixed_version: "1.14.1"
    })

    {:ok, admin: admin, editor: editor, viewer: viewer, project: project, repo: repo}
  end

  describe "GET /admin/repositories/:id/sbom.cdx.json" do
    test "requires authentication", %{conn: conn, repo: repo} do
      conn = get(conn, ~p"/admin/repositories/#{repo.id}/sbom.cdx.json")
      assert redirected_to(conn) =~ "/users/log-in"
    end

    test "denies access to viewers without editor/admin role", %{
      conn: conn,
      viewer: viewer,
      repo: repo
    } do
      conn =
        conn
        |> log_in_user(viewer)
        |> get(~p"/admin/repositories/#{repo.id}/sbom.cdx.json")

      assert redirected_to(conn) == "/domains"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "permission"
    end

    test "downloads valid CycloneDX 1.5 JSON for editors", %{
      conn: conn,
      editor: editor,
      repo: repo
    } do
      conn =
        conn
        |> log_in_user(editor)
        |> get(~p"/admin/repositories/#{repo.id}/sbom.cdx.json")

      assert response(conn, 200)
      assert response_content_type(conn, :json) =~ "application/vnd.cyclonedx+json"

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment; filename=\"testorg_sbom-test-repo-"
      assert disposition =~ "-sbom.cdx.json\""

      body = response(conn, 200)
      decoded = Jason.decode!(body)

      assert decoded["bomFormat"] == "CycloneDX"
      assert decoded["specVersion"] == "1.5"
      assert decoded["metadata"]["component"]["name"] == repo.external_id
      assert length(decoded["components"]) >= 1
      assert length(decoded["vulnerabilities"]) == 1

      [vuln] = decoded["vulnerabilities"]
      assert vuln["id"] == "CVE-2024-5555"
      assert vuln["recommendation"] == "Upgrade plug to 1.14.1"
    end
  end

  describe "GET /admin/projects/:id/sbom.cdx.json" do
    test "requires authentication", %{conn: conn, project: project} do
      conn = get(conn, ~p"/admin/projects/#{project.id}/sbom.cdx.json")
      assert redirected_to(conn) =~ "/users/log-in"
    end

    test "denies access to viewers", %{conn: conn, viewer: viewer, project: project} do
      conn =
        conn
        |> log_in_user(viewer)
        |> get(~p"/admin/projects/#{project.id}/sbom.cdx.json")

      assert redirected_to(conn) == "/domains"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "permission"
    end

    test "downloads aggregated CycloneDX 1.5 JSON for admins", %{
      conn: conn,
      admin: admin,
      project: project
    } do
      conn =
        conn
        |> log_in_user(admin)
        |> get(~p"/admin/projects/#{project.id}/sbom.cdx.json")

      assert response(conn, 200)
      assert response_content_type(conn, :json) =~ "application/vnd.cyclonedx+json"

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment; filename=\"#{project.slug}-sbom.cdx.json\""

      body = response(conn, 200)
      decoded = Jason.decode!(body)

      assert decoded["bomFormat"] == "CycloneDX"
      assert decoded["specVersion"] == "1.5"
      assert decoded["metadata"]["component"]["name"] == project.slug
      assert length(decoded["components"]) >= 1
      assert length(decoded["vulnerabilities"]) == 1
    end
  end
end
