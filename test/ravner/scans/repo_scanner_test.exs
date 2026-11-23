defmodule Ravner.Scans.RepoScannerTest do
  use Ravner.DataCase, async: false

  alias Ravner.DomainsFixtures
  alias Ravner.Integrations.VCS
  alias Ravner.Inventory
  alias Ravner.Repo
  alias Ravner.Scans.CveCacheEntry
  alias Ravner.Scans.RepoScanner
  alias Ravner.SecurityScans
  alias Ravner.SecurityScans.SecurityScan

  setup do
    original_cve_opts = Application.get_env(:ravner, :cve_lookup_req_opts)
    original_bb_opts = Application.get_env(:ravner, :bitbucket_req_opts)

    Repo.delete_all(CveCacheEntry)

    if :ets.whereis(:cve_cache_table) != :undefined do
      :ets.delete_all_objects(:cve_cache_table)
    end

    on_exit(fn ->
      restore_env(:cve_lookup_req_opts, original_cve_opts)
      restore_env(:bitbucket_req_opts, original_bb_opts)
    end)

    # Set up test admin user for Ash actions
    admin = Ravner.AccountsFixtures.user_fixture()
    {:ok, admin} = admin |> Ravner.Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()

    # Create VCS integration
    {:ok, _integration} =
      VCS.create_integration(%{
        name: "Test Bitbucket",
        provider: "bitbucket",
        workspace: "testorg",
        token: "secret_token_123",
        active: true
      })

    domain =
      DomainsFixtures.domain_fixture(%{
        name: "scan-test-#{System.unique_integer([:positive])}.com"
      })

    {:ok, admin: admin, domain: domain}
  end

  defp restore_env(key, nil), do: Application.delete_env(:ravner, key)
  defp restore_env(key, value), do: Application.put_env(:ravner, key, value)

  defp stub_bitbucket_files(files_map) do
    plug = fn conn ->
      path = conn.request_path
      # Matches: /2.0/repositories/:workspace/:slug/src/:branch/:filename
      matched_file =
        Enum.find(files_map, fn {filename, _content} ->
          String.ends_with?(path, "/#{filename}")
        end)

      case matched_file do
        {_filename, content} ->
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.send_resp(200, content)

        nil ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            404,
            Jason.encode!(%{"type" => "error", "error" => %{"message" => "Not found"}})
          )
      end
    end

    Application.put_env(:ravner, :bitbucket_req_opts, plug: plug)
  end

  defp stub_osv_responses(vuln_map) do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      results =
        Enum.map(decoded["queries"] || [], fn q ->
          pkg = get_in(q, ["package", "name"])
          ver = q["version"]
          vulns = Map.get(vuln_map, {pkg, ver}, [])
          %{"vulns" => vulns}
        end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"results" => results}))
    end

    Application.put_env(:ravner, :cve_lookup_req_opts, plug: plug)
  end

  test "marks repository clean when no manifest files exist", %{admin: admin, domain: domain} do
    {:ok, repo} =
      Inventory.create_project_repository(
        %{
          domain_id: domain.id,
          url: "https://bitbucket.org/testorg/empty-repo",
          provider: "bitbucket",
          external_id: "empty-repo",
          kind: "app"
        },
        actor: admin
      )

    stub_bitbucket_files(%{})
    stub_osv_responses(%{})

    assert {:ok, %{repository: updated_repo, vulnerabilities: []}} =
             RepoScanner.scan_repository(repo.id)

    assert updated_repo.scan_status == "clean"
    assert updated_repo.vulnerability_count == 0
    assert updated_repo.last_scanned_at != nil
    assert SecurityScans.list_repository_vulnerabilities(repo.id) == []
  end

  test "scans mix.lock, detects CVEs, updates repo counters, and creates domain security scan",
       %{admin: admin, domain: domain} do
    {:ok, repo} =
      Inventory.create_project_repository(
        %{
          domain_id: domain.id,
          url: "https://bitbucket.org/testorg/elixir-app",
          provider: "bitbucket",
          external_id: "elixir-app",
          kind: "api"
        },
        actor: admin
      )

    mix_lock_content = """
    %{
      "plug": {:hex, :plug, "1.14.0", "hash", [:mix], [], "hexpm", "hash"},
      "decimal": {:hex, :decimal, "2.2.0", "hash", [:mix], [], "hexpm", "hash"}
    }
    """

    stub_bitbucket_files(%{"mix.lock" => mix_lock_content})

    stub_osv_responses(%{
      {"plug", "1.14.0"} => [
        %{
          "id" => "GHSA-plug-test-1234",
          "aliases" => ["CVE-2023-99999"],
          "summary" => "Header parsing vulnerability in Plug",
          "details" => "Detailed description of vulnerability in Plug",
          "affected" => [
            %{
              "package" => %{"name" => "plug", "ecosystem" => "Hex"},
              "ranges" => [
                %{
                  "type" => "ECOSYSTEM",
                  "events" => [
                    %{"introduced" => "1.0.0"},
                    %{"fixed" => "1.14.1"}
                  ]
                }
              ],
              "severity" => [
                %{"type" => "CVSS_V3", "score" => "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}
              ]
            }
          ]
        }
      ]
    })

    assert {:ok, %{repository: updated_repo, vulnerabilities: vulns}} =
             RepoScanner.scan_repository(repo.id)

    assert updated_repo.scan_status == "vulnerable"
    assert updated_repo.vulnerability_count == 1
    assert updated_repo.critical_vuln_count == 1
    assert length(vulns) == 1

    [v] = vulns
    assert v.cve_id == "CVE-2023-99999"
    assert v.package_name == "plug"
    assert v.package_version == "1.14.0"
    assert v.ecosystem == "Hex"
    assert v.severity == "critical"
    assert v.fixed_version == "1.14.1"
    assert v.manifest_file == "mix.lock"

    # Verify persisted in database
    persisted = SecurityScans.list_repository_vulnerabilities(repo.id)
    assert length(persisted) == 1
    assert hd(persisted).cve_id == "CVE-2023-99999"

    # Verify domain security scan created
    domain_scans =
      SecurityScan
      |> where(domain_id: ^domain.id, tool: "repo_sca")
      |> Repo.all()
      |> Repo.preload(:findings)

    assert length(domain_scans) == 1
    [sec_scan] = domain_scans
    assert sec_scan.status == "completed"
    assert length(sec_scan.findings) == 1
    assert hd(sec_scan.findings).severity == "critical"
    assert hd(sec_scan.findings).detail["source"] == "repo_sca"
  end

  test "returns error when repository cannot be resolved" do
    assert {:error, "Repository 999999 not found"} = RepoScanner.scan_repository(999_999)
  end
end
