defmodule Ravner.Scans.SbomSerializerTest do
  use Ravner.DataCase, async: true

  alias Ravner.AccountsFixtures
  alias Ravner.Inventory
  alias Ravner.Repo
  alias Ravner.Scans.ProjectRepositoryVulnerability
  alias Ravner.Scans.SbomSerializer

  defp create_project_and_admin(attrs) do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
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

    name = Map.get(attrs, :name, "Project #{suffix}")
    slug = Map.get(attrs, :slug, "proj-#{suffix}")

    {:ok, project} =
      Inventory.create_project(
        %{name: name, slug: slug, organization_id: org.id},
        actor: admin
      )

    {project, admin}
  end

  describe "purl/3" do
    test "formats Hex package purl" do
      assert SbomSerializer.purl("Hex", "phoenix", "1.7.14") == "pkg:hex/phoenix@1.7.14"
      assert SbomSerializer.purl("hex", "ecto", "3.11.0") == "pkg:hex/ecto@3.11.0"
    end

    test "formats npm packages including scoped packages" do
      assert SbomSerializer.purl("npm", "lodash", "4.17.21") == "pkg:npm/lodash@4.17.21"

      assert SbomSerializer.purl("npm", "@angular/core", "16.2.0") ==
               "pkg:npm/%40angular/core@16.2.0"

      assert SbomSerializer.purl("npm", "@types/node", "20.5.0") == "pkg:npm/%40types/node@20.5.0"
    end

    test "formats PyPI packages normalized with lowercase and hyphens" do
      assert SbomSerializer.purl("PyPI", "Django", "4.2.1") == "pkg:pypi/django@4.2.1"

      assert SbomSerializer.purl("pypi", "urllib3_secure", "1.26.18") ==
               "pkg:pypi/urllib3-secure@1.26.18"
    end

    test "formats Packagist / Composer packages" do
      assert SbomSerializer.purl("Packagist", "laravel/framework", "10.0.0") ==
               "pkg:composer/laravel/framework@10.0.0"

      assert SbomSerializer.purl("composer", "symfony/http-foundation", "6.3.0") ==
               "pkg:composer/symfony/http-foundation@6.3.0"
    end

    test "formats Go packages" do
      assert SbomSerializer.purl("Go", "github.com/gin-gonic/gin", "v1.9.1") ==
               "pkg:golang/github.com/gin-gonic/gin@v1.9.1"
    end

    test "formats crates.io / Cargo packages" do
      assert SbomSerializer.purl("crates.io", "serde", "1.0.197") == "pkg:cargo/serde@1.0.197"
      assert SbomSerializer.purl("cargo", "tokio", "1.35.0") == "pkg:cargo/tokio@1.35.0"
    end

    test "formats RubyGems packages" do
      assert SbomSerializer.purl("RubyGems", "rails", "7.1.0") == "pkg:gem/rails@7.1.0"
      assert SbomSerializer.purl("gem", "nokogiri", "1.15.4") == "pkg:gem/nokogiri@1.15.4"
    end

    test "handles versionless packages and fallback ecosystems" do
      assert SbomSerializer.purl("hex", "phoenix", nil) == "pkg:hex/phoenix"
      assert SbomSerializer.purl("hex", "phoenix", "") == "pkg:hex/phoenix"
      assert SbomSerializer.purl("custom_eco", "my_pkg", "0.1.0") == "pkg:custom_eco/my_pkg@0.1.0"
      assert SbomSerializer.purl(nil, "foo", "1.0.0") == "pkg:generic/foo@1.0.0"
      assert SbomSerializer.purl("generic", nil, "1.0.0") == "pkg:generic/unknown"
    end
  end

  describe "generate/3" do
    test "generates a compliant CycloneDX 1.5 JSON map" do
      deps = [
        {"phoenix", "1.7.14", "Hex", "mix.lock"},
        {"ecto", "3.11.0", "Hex", "mix.lock"},
        {"@heroicons/react", "2.0.18", "npm", "package.json"}
      ]

      vulns = [
        %{
          cve_id: "CVE-2024-9999",
          package_name: "phoenix",
          package_version: "1.7.14",
          ecosystem: "Hex",
          severity: "high",
          summary: "XSS vulnerability in HTML escaping",
          fixed_version: "1.7.15"
        }
      ]

      meta = %{
        name: "my-service",
        version: "2.1.0",
        description: "Payment microservice"
      }

      {:ok, bom} = SbomSerializer.generate(meta, deps, vulnerabilities: vulns)

      assert bom["$schema"] == "http://cyclonedx.org/schema/bom-1.5.schema.json"
      assert bom["bomFormat"] == "CycloneDX"
      assert bom["specVersion"] == "1.5"
      assert String.starts_with?(bom["serialNumber"], "urn:uuid:")
      assert bom["version"] == 1

      # Metadata assertions
      metadata = bom["metadata"]
      assert metadata["component"]["name"] == "my-service"
      assert metadata["component"]["version"] == "2.1.0"
      assert metadata["component"]["description"] == "Payment microservice"

      assert [%{"name" => "Ravner ASM", "vendor" => "Ravner", "version" => "0.11.0"}] =
               metadata["tools"]

      # Components assertions
      components = bom["components"]
      assert length(components) == 3

      phoenix_comp = Enum.find(components, &(&1["name"] == "phoenix"))
      assert phoenix_comp["purl"] == "pkg:hex/phoenix@1.7.14"
      assert phoenix_comp["bom-ref"] == "pkg:hex/phoenix@1.7.14"
      assert phoenix_comp["version"] == "1.7.14"
      assert phoenix_comp["scope"] == "required"

      assert phoenix_comp["properties"] == [
               %{"name" => "ravner:manifest_file", "value" => "mix.lock"}
             ]

      heroicons_comp = Enum.find(components, &(&1["name"] == "@heroicons/react"))
      assert heroicons_comp["purl"] == "pkg:npm/%40heroicons/react@2.0.18"

      # Vulnerabilities assertions
      vulnerabilities = bom["vulnerabilities"]
      assert length(vulnerabilities) == 1
      [v] = vulnerabilities
      assert v["id"] == "CVE-2024-9999"
      assert v["source"] == %{"name" => "NVD"}
      assert [%{"severity" => "high", "method" => "other"}] = v["ratings"]
      assert v["affects"] == [%{"ref" => "pkg:hex/phoenix@1.7.14"}]
      assert v["recommendation"] == "Upgrade phoenix to 1.7.15"
      assert v["description"] == "XSS vulnerability in HTML escaping"
    end

    test "omits vulnerabilities key when no vulnerabilities exist" do
      deps = [{"jason", "1.4.1", "Hex"}]
      {:ok, bom} = SbomSerializer.generate(%{name: "clean-app"}, deps)

      refute Map.has_key?(bom, "vulnerabilities")
      assert length(bom["components"]) == 1
    end

    test "deduplicates components by purl and sorts alphabetically" do
      deps = [
        {"plug", "1.14.0", "Hex", "mix.lock"},
        {"plug", "1.14.0", "Hex", "another.lock"},
        {"absinthe", "1.7.0", "Hex", "mix.lock"}
      ]

      {:ok, bom} = SbomSerializer.generate(%{name: "sorter"}, deps)
      components = bom["components"]

      assert length(components) == 2
      assert Enum.map(components, & &1["name"]) == ["absinthe", "plug"]
    end
  end

  describe "to_json/1 and to_json!/1" do
    test "serializes bom to valid JSON" do
      {:ok, bom} = SbomSerializer.generate(%{name: "json-app"}, [{"req", "0.5.0", "Hex"}])
      assert {:ok, json_str} = SbomSerializer.to_json(bom)
      assert is_binary(json_str)

      decoded = Jason.decode!(json_str)
      assert decoded["bomFormat"] == "CycloneDX"
      assert decoded["specVersion"] == "1.5"

      raw_json = SbomSerializer.to_json!(bom)
      assert raw_json == json_str
    end
  end

  describe "generate_for_repository/2" do
    test "generates SBOM for a ProjectRepository with vulnerabilities" do
      {project, admin} = create_project_and_admin(%{name: "Inventory System"})

      {:ok, repo} =
        Inventory.create_project_repository(
          %{
            url: "https://bitbucket.org/testorg/inventory-svc.git",
            external_id: "testorg/inventory-svc",
            kind: "api",
            provider: "bitbucket",
            project_id: project.id,
            last_commit_hash: "abc12345"
          },
          actor: admin
        )

      # Insert a repository vulnerability record
      _vuln =
        Repo.insert!(%ProjectRepositoryVulnerability{
          project_repository_id: repo.id,
          cve_id: "CVE-2023-45853",
          osv_id: "GHSA-7h5u-xwv2-8x79",
          package_name: "zlib",
          package_version: "1.2.11",
          ecosystem: "generic",
          severity: "critical",
          summary: "Buffer overflow in miniunz",
          fixed_version: "1.2.12",
          manifest_file: "mix.lock"
        })

      # Generate passing mock dependencies
      mock_deps = [
        {"phoenix", "1.7.10", "Hex", "mix.lock"},
        {"ecto_sql", "3.10.2", "Hex", "mix.lock"}
      ]

      {:ok, bom} =
        SbomSerializer.generate_for_repository(repo, dependencies: mock_deps)

      assert bom["metadata"]["component"]["name"] == "testorg/inventory-svc"
      assert bom["metadata"]["component"]["version"] == "abc12345"

      # Component count should include mock_deps + the vulnerable package zlib
      comp_names = Enum.map(bom["components"], & &1["name"])
      assert "phoenix" in comp_names
      assert "ecto_sql" in comp_names
      assert "zlib" in comp_names

      # Vulnerabilities check
      assert length(bom["vulnerabilities"]) == 1
      assert hd(bom["vulnerabilities"])["id"] == "CVE-2023-45853"

      assert hd(bom["vulnerabilities"])["ratings"] == [
               %{"method" => "other", "severity" => "critical"}
             ]
    end

    test "falls back to database vulnerabilities when VCS dependencies cannot be fetched" do
      {project, admin} = create_project_and_admin(%{name: "Fallback Test"})

      {:ok, repo} =
        Inventory.create_project_repository(
          %{
            url: "https://bitbucket.org/testorg/unconnected.git",
            external_id: "testorg/unconnected",
            kind: "api",
            provider: "bitbucket",
            project_id: project.id
          },
          actor: admin
        )

      Repo.insert!(%ProjectRepositoryVulnerability{
        project_repository_id: repo.id,
        cve_id: "CVE-2024-1111",
        osv_id: "GHSA-1111-2222-3333",
        package_name: "openssl",
        package_version: "1.1.1",
        ecosystem: "generic",
        severity: "high",
        summary: "Memory leak",
        fixed_version: "1.1.2"
      })

      # When no VCS credentials exist, it falls back to DB vulnerabilities
      {:ok, bom} = SbomSerializer.generate_for_repository(repo)

      assert length(bom["components"]) == 1
      assert hd(bom["components"])["name"] == "openssl"
      assert length(bom["vulnerabilities"]) == 1
    end
  end

  describe "generate_for_project/2" do
    test "aggregates dependencies and vulnerabilities across multiple repositories" do
      {project, admin} = create_project_and_admin(%{name: "Core Platform", slug: "core-platform"})

      {:ok, repo1} =
        Inventory.create_project_repository(
          %{
            url: "https://bitbucket.org/testorg/auth-service.git",
            external_id: "testorg/auth-service",
            kind: "api",
            provider: "bitbucket",
            project_id: project.id
          },
          actor: admin
        )

      {:ok, repo2} =
        Inventory.create_project_repository(
          %{
            url: "https://bitbucket.org/testorg/frontend-app.git",
            external_id: "testorg/frontend-app",
            kind: "website",
            provider: "bitbucket",
            project_id: project.id
          },
          actor: admin
        )

      Repo.insert!(%ProjectRepositoryVulnerability{
        project_repository_id: repo1.id,
        cve_id: "CVE-2024-0001",
        osv_id: "GHSA-0001-0001-0001",
        package_name: "guardian",
        package_version: "2.3.0",
        ecosystem: "Hex",
        severity: "high",
        summary: "JWT validation bypass"
      })

      Repo.insert!(%ProjectRepositoryVulnerability{
        project_repository_id: repo2.id,
        cve_id: "CVE-2024-0002",
        osv_id: "GHSA-0002-0002-0002",
        package_name: "axios",
        package_version: "0.21.1",
        ecosystem: "npm",
        severity: "medium",
        summary: "SSRF flaw"
      })

      mock_deps = [
        {"guardian", "2.3.0", "Hex", "mix.lock"},
        {"phoenix", "1.7.14", "Hex", "mix.lock"},
        {"axios", "0.21.1", "npm", "package.json"},
        {"react", "18.2.0", "npm", "package.json"}
      ]

      {:ok, bom} = SbomSerializer.generate_for_project(project, dependencies: mock_deps)

      assert bom["metadata"]["component"]["name"] == "core-platform"
      assert length(bom["components"]) == 4
      assert length(bom["vulnerabilities"]) == 2

      cve_ids = Enum.map(bom["vulnerabilities"], & &1["id"])
      assert "CVE-2024-0001" in cve_ids
      assert "CVE-2024-0002" in cve_ids
    end
  end
end
