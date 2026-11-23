defmodule Ravner.Scans.CveCacheTest do
  use Ravner.DataCase, async: false

  alias Ravner.Repo
  alias Ravner.Scans.CveCache
  alias Ravner.Scans.CveCacheEntry

  setup do
    # Clean ETS and DB before each test
    Repo.delete_all(CveCacheEntry)

    if :ets.whereis(:cve_cache_table) != :undefined do
      :ets.delete_all_objects(:cve_cache_table)
    end

    :ok
  end

  test "fetch_batch caches external results in both ETS and PostgreSQL" do
    queries = [{"next", "14.2.0", "npm", "next"}]

    vulns = [
      %{
        "id" => "GHSA-test-1234",
        "summary" => "Test vulnerability in Next.js",
        "aliases" => ["CVE-2024-9999"]
      }
    ]

    fetch_counter = :counters.new(1, [:atomics])

    fetch_fn = fn q ->
      :counters.add(fetch_counter, 1, 1)
      Map.new(q, fn {name, ver, _, _} -> {{name, ver}, vulns} end)
    end

    # First call: cache miss, external fetch_fn is invoked
    result1 = CveCache.fetch_batch(queries, fetch_fn)
    assert :counters.get(fetch_counter, 1) == 1
    assert result1[{"next", "14.2.0"}] == vulns

    # Verify persisted in PostgreSQL
    db_entry = Repo.get_by(CveCacheEntry, ecosystem: "npm", package: "next", version: "14.2.0")
    assert db_entry != nil
    assert db_entry.findings == vulns

    # Second call: L1 (ETS) hit — fetch_fn must NOT be called
    result2 = CveCache.fetch_batch(queries, fetch_fn)
    assert :counters.get(fetch_counter, 1) == 1
    assert result2[{"next", "14.2.0"}] == vulns

    # Clear ETS to simulate fresh worker or restart
    :ets.delete_all_objects(:cve_cache_table)

    # Third call: L2 (PostgreSQL) hit — repopulates ETS, fetch_fn must NOT be called
    result3 = CveCache.fetch_batch(queries, fetch_fn)
    assert :counters.get(fetch_counter, 1) == 1
    assert result3[{"next", "14.2.0"}] == vulns

    # Now ETS is warm again
    assert [{_, ^vulns, _}] = :ets.lookup(:cve_cache_table, {"npm", "next", "14.2.0"})
  end

  test "fetch_batch treats expired entries as misses and refreshes them" do
    queries = [{"astro", "4.0.0", "npm", "astro"}]

    # Pre-seed an expired entry in DB
    past = DateTime.add(DateTime.utc_now(), -3600, :second)

    %CveCacheEntry{}
    |> CveCacheEntry.changeset(%{
      ecosystem: "npm",
      package: "astro",
      version: "4.0.0",
      findings: [%{"id" => "OLD-VULN"}],
      queried_at: past,
      expires_at: past
    })
    |> Repo.insert!()

    new_vulns = [%{"id" => "NEW-VULN"}]

    fetch_fn = fn q ->
      Map.new(q, fn {name, ver, _, _} -> {{name, ver}, new_vulns} end)
    end

    result = CveCache.fetch_batch(queries, fetch_fn)
    assert result[{"astro", "4.0.0"}] == new_vulns

    # Verify updated in DB with future expiration
    db_entry = Repo.get_by(CveCacheEntry, ecosystem: "npm", package: "astro", version: "4.0.0")
    assert db_entry.findings == new_vulns
    assert DateTime.compare(db_entry.expires_at, DateTime.utc_now()) == :gt
  end

  test "prune_expired removes stale records from DB and ETS" do
    # Stale entry
    CveCache.put("npm", "stale_pkg", "1.0", [%{"id" => "STALE"}], -3600)
    # Fresh entry
    CveCache.put("npm", "fresh_pkg", "1.0", [%{"id" => "FRESH"}], 3600)

    assert Repo.aggregate(CveCacheEntry, :count) == 2

    CveCache.prune_expired()

    assert Repo.aggregate(CveCacheEntry, :count) == 1
    assert Repo.get_by(CveCacheEntry, package: "stale_pkg") == nil
    assert Repo.get_by(CveCacheEntry, package: "fresh_pkg") != nil
  end
end
