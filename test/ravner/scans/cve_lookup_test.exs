defmodule Ravner.Scans.CveLookupTest do
  use Ravner.DataCase, async: false

  import Ravner.DomainsFixtures

  alias Ravner.Domains
  alias Ravner.Repo
  alias Ravner.Scans.CveCacheEntry
  alias Ravner.Scans.CveLookup

  setup do
    original_opts = Application.get_env(:ravner, :cve_lookup_req_opts)
    original_enabled = Application.get_env(:ravner, :cve_lookup_enabled)

    Repo.delete_all(CveCacheEntry)

    if :ets.whereis(:cve_cache_table) != :undefined do
      :ets.delete_all_objects(:cve_cache_table)
    end

    on_exit(fn ->
      restore_env(:cve_lookup_req_opts, original_opts)
      restore_env(:cve_lookup_enabled, original_enabled)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:ravner, key)
  defp restore_env(key, value), do: Application.put_env(:ravner, key, value)

  defp stub_osv(fun) do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:osv_request, Jason.decode!(body)})
      fun.(conn)
    end

    Application.put_env(:ravner, :cve_lookup_req_opts, plug: plug)
  end

  defp osv_response(conn, vulns) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"results" => vulns}))
  end

  test "maps tech evidence with versions to CVE findings" do
    domain = domain_fixture()

    Domains.sync_tech_evidence(domain.id, [
      %{"name" => "jQuery", "version" => "3.6.0"}
    ])

    stub_osv(fn conn ->
      osv_response(conn, [
        %{
          "vulns" => [
            %{
              "id" => "GHSA-xxxx-yyyy-zzzz",
              "summary" => "XSS in jQuery",
              "aliases" => ["CVE-2020-11023"],
              "database_specific" => %{"severity" => "HIGH"},
              "references" => [%{"url" => "https://nvd.nist.gov/vuln/detail/CVE-2020-11023"}]
            }
          ]
        }
      ])
    end)

    assert {:ok, [finding]} = CveLookup.lookup(domain.id, domain.name)

    assert finding.severity == "high"
    assert finding.title =~ "CVE-2020-11023"
    assert finding.title =~ "jQuery v3.6.0"
    assert finding.target == domain.name
    assert finding.detail["cve"] == "CVE-2020-11023"
    assert finding.detail["osv_id"] == "GHSA-xxxx-yyyy-zzzz"
    assert "https://nvd.nist.gov/vuln/detail/CVE-2020-11023" in finding.detail["references"]
    assert "https://osv.dev/vulnerability/GHSA-xxxx-yyyy-zzzz" in finding.detail["references"]
    assert finding.detail["source"] == "osv.dev"

    assert_received {:osv_request, %{"queries" => [query]}}

    assert query == %{
             "package" => %{"name" => "jquery", "ecosystem" => "npm"},
             "version" => "3.6.0"
           }
  end

  test "supports modern web frameworks (Next.js, Astro, Payload, Svelte, Django)" do
    map = CveLookup.ecosystem_map()

    assert map["next.js"] == {"npm", "next"}
    assert map["astro"] == {"npm", "astro"}
    assert map["payload"] == {"npm", "payload"}
    assert map["svelte"] == {"npm", "svelte"}
    assert map["sveltekit"] == {"npm", "@sveltejs/kit"}
    assert map["vue"] == {"npm", "vue"}
    assert map["nuxt"] == {"npm", "nuxt"}
    assert map["django"] == {"PyPI", "django"}
    assert map["fastapi"] == {"PyPI", "fastapi"}
    assert map["wordpress"] == {"Bitnami", "wordpress"}
    assert map["nginx"] == {"Debian", "nginx"}
  end

  test "returns empty list when no mappable evidence exists" do
    domain = domain_fixture()

    Domains.sync_tech_evidence(domain.id, [
      %{"name" => "CompletelyUnknownLibXYZ", "version" => "1.0.0"}
    ])

    assert {:ok, []} = CveLookup.lookup(domain.id, domain.name)
  end

  test "returns empty list when evidence has no versions" do
    domain = domain_fixture()
    Domains.sync_tech_evidence(domain.id, [%{"name" => "jQuery"}])

    assert {:ok, []} = CveLookup.lookup(domain.id, domain.name)
  end

  test "gracefully handles OSV API errors" do
    domain = domain_fixture()
    Domains.sync_tech_evidence(domain.id, [%{"name" => "jQuery", "version" => "3.6.0"}])

    stub_osv(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert {:error, {:osv_unavailable, _reason}} = CveLookup.lookup(domain.id, domain.name)
  end

  test "is disabled via config" do
    Application.put_env(:ravner, :cve_lookup_enabled, false)

    domain = domain_fixture()
    Domains.sync_tech_evidence(domain.id, [%{"name" => "jQuery", "version" => "3.6.0"}])

    assert {:ok, []} = CveLookup.lookup(domain.id, domain.name)
  end

  test "maps missing severity to medium" do
    domain = domain_fixture()
    Domains.sync_tech_evidence(domain.id, [%{"name" => "Lodash", "version" => "4.17.20"}])

    stub_osv(fn conn ->
      osv_response(conn, [
        %{"vulns" => [%{"id" => "GHSA-1111", "summary" => "Prototype pollution"}]}
      ])
    end)

    assert {:ok, [finding]} = CveLookup.lookup(domain.id, domain.name)
    assert finding.severity == "medium"
  end

  test "does not query OSV when version is empty string or whitespace" do
    domain = domain_fixture()

    Domains.sync_tech_evidence(domain.id, [
      %{"name" => "PHP", "version" => ""},
      %{"name" => "WordPress", "version" => "   "}
    ])

    # If OSV is queried, this test will fail or fail to stub
    assert {:ok, []} = CveLookup.lookup(domain.id, domain.name)
  end

  test "excludes implied technologies (confidence 50 or source wappalyzer:implied) from CVE queries" do
    domain = domain_fixture()

    Domains.sync_tech_evidence(domain.id, [
      %{
        "name" => "PHP",
        "version" => "8.1.0",
        "confidence" => 50,
        "source" => "wappalyzer:implied"
      },
      %{"name" => "Node.js", "version" => "18.0.0", "confidence" => 50, "implied" => true}
    ])

    assert {:ok, []} = CveLookup.lookup(domain.id, domain.name)
  end

  test "valid_version? correctly validates version strings" do
    assert CveLookup.valid_version?("1.0.0")
    assert CveLookup.valid_version?("3.6.0")
    assert CveLookup.valid_version?("10")
    assert CveLookup.valid_version?("2.4.52")

    refute CveLookup.valid_version?("")
    refute CveLookup.valid_version?("   ")
    refute CveLookup.valid_version?(nil)
    refute CveLookup.valid_version?("unknown")
    refute CveLookup.valid_version?("latest")
  end

  test "keeps unfixed vulnerabilities for explicit product-level triage" do
    domain = domain_fixture()

    Domains.sync_tech_evidence(domain.id, [
      %{
        "name" => "nginx",
        "version" => "1.21.6",
        "confidence" => 100,
        "source" => "wappalyzer:direct"
      }
    ])

    stub_osv(fn conn ->
      osv_response(conn, [
        %{
          "vulns" => [
            %{
              "id" => "DEBIAN-CVE-2009-4487",
              "summary" => "Symlink vulnerability in Debian nginx",
              "affected" => [
                %{
                  "package" => %{"name" => "nginx", "ecosystem" => "Debian"},
                  "ranges" => [
                    %{"type" => "ECOSYSTEM", "events" => [%{"introduced" => "0"}]}
                  ]
                }
              ]
            },
            %{
              "id" => "DEBIAN-CVE-2022-41741",
              "summary" => "Real vulnerability in mp4 module",
              "aliases" => ["CVE-2022-41741"],
              "affected" => [
                %{
                  "package" => %{"name" => "nginx", "ecosystem" => "Debian"},
                  "ranges" => [
                    %{
                      "type" => "ECOSYSTEM",
                      "events" => [%{"introduced" => "1.21.0"}, %{"fixed" => "1.23.2"}]
                    }
                  ]
                }
              ]
            }
          ]
        }
      ])
    end)

    assert {:ok, findings} = CveLookup.lookup(domain.id, domain.name)
    assert Enum.map(findings, & &1.detail["cve"]) == ["CVE-2009-4487", "CVE-2022-41741"]
  end
end
