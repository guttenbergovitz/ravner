defmodule Ravner.Scans.CveCache do
  @moduledoc """
  Two-layer (L1: ETS memory, L2: PostgreSQL) cache for OSV.dev CVE lookups.

  Keyed by `{ecosystem, package, version}`, ensuring that vulnerabilities for
  common frameworks (Next.js, Django, Vue, WordPress, etc.) are fetched
  once across all domains in the inventory and retained across restarts.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Ravner.Repo
  alias Ravner.Scans.CveCacheEntry

  @table_name :cve_cache_table
  @default_ttl_seconds 86_400

  # ─── Client API ───────────────────────────────────────────────────────────

  @doc """
  Starts the CVE cache GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fetches vulnerability findings for a batch of `{name, version, ecosystem, package}` queries.

  Resolves from:
  1. L1 Memory (ETS) in microseconds
  2. L2 Database (PostgreSQL `cve_cache`)
  3. External `fetch_fn` (OSV.dev batch API) for cache misses only

  Results are written back to both L1 and L2 caches.
  """
  @spec fetch_batch(
          list({String.t(), String.t(), String.t(), String.t()}),
          (list({String.t(), String.t(), String.t(), String.t()}) -> map())
        ) :: map()
  def fetch_batch(queries, fetch_fn) when is_list(queries) and is_function(fetch_fn, 1) do
    now = DateTime.utc_now()
    ttl = Application.get_env(:ravner, :cve_cache_ttl, @default_ttl_seconds)

    # 1. Check L1: ETS
    {l1_hits, l1_misses} = partition_by_ets(queries, now)

    # 2. Check L2: PostgreSQL for L1 misses
    {l2_hits, l2_misses} =
      if l1_misses != [] do
        partition_by_db(l1_misses, now)
      else
        {[], []}
      end

    # Populate ETS with L2 hits
    Enum.each(l2_hits, fn {{eco, pkg, ver}, _name_ver, findings, expires_at} ->
      insert_ets(eco, pkg, ver, findings, expires_at)
    end)

    # 3. Fetch remaining misses from external source
    external_result =
      if l2_misses != [] do
        fetch_fn.(l2_misses)
      else
        %{}
      end

    case external_result do
      {:error, reason} ->
        {:error, reason}

      results when is_map(results) ->
        expires_at = DateTime.add(now, ttl, :second)

        Enum.each(l2_misses, fn {name, version, eco, pkg} ->
          findings = Map.get(results, {name, version}, [])
          insert_ets(eco, pkg, version, findings, expires_at)
          persist_db(eco, pkg, version, findings, now, expires_at)
        end)

        Enum.reduce(l1_hits, %{}, fn {{name, version}, findings}, acc ->
          Map.put(acc, {name, version}, findings)
        end)
        |> Map.merge(
          Enum.reduce(l2_hits, %{}, fn {_eco_key, {name, version}, findings, _exp}, acc ->
            Map.put(acc, {name, version}, findings)
          end)
        )
        |> Map.merge(results)
    end
  end

  @doc """
  Looks up an entry from L1 (ETS) or L2 (DB).
  """
  @spec get(String.t(), String.t(), String.t()) :: {:ok, list(map())} | :miss
  def get(ecosystem, package, version) do
    now = DateTime.utc_now()

    case lookup_ets(ecosystem, package, version, now) do
      {:ok, findings} ->
        {:ok, findings}

      :miss ->
        case lookup_db(ecosystem, package, version, now) do
          {:ok, findings, expires_at} ->
            insert_ets(ecosystem, package, version, findings, expires_at)
            {:ok, findings}

          :miss ->
            :miss
        end
    end
  end

  @doc """
  Directly puts an entry into L1 (ETS) and L2 (DB).
  """
  def put(ecosystem, package, version, findings, ttl \\ @default_ttl_seconds) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, ttl, :second)

    insert_ets(ecosystem, package, version, findings, expires_at)
    persist_db(ecosystem, package, version, findings, now, expires_at)
  end

  @doc """
  Cleans expired entries from both ETS and PostgreSQL.
  """
  def prune_expired do
    now = DateTime.utc_now()

    # Prune DB
    from(c in CveCacheEntry, where: c.expires_at <= ^now)
    |> Repo.delete_all()

    # Prune ETS
    if :ets.whereis(@table_name) != :undefined do
      match_spec = [{{:_, :_, :_, :_, :"$1"}, [{:"=<", :"$1", {:const, now}}], [true]}]
      :ets.select_delete(@table_name, match_spec)
    end

    :ok
  rescue
    e ->
      Logger.warning("CveCache prune failed: #{inspect(e)}")
      :ok
  end

  # ─── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    ensure_ets_table()
    warm_from_db()
    {:ok, %{}}
  end

  defp ensure_ets_table do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end
  end

  defp warm_from_db do
    now = DateTime.utc_now()

    entries =
      from(c in CveCacheEntry,
        where: c.expires_at > ^now,
        select: {c.ecosystem, c.package, c.version, c.findings, c.expires_at}
      )
      |> Repo.all()

    Enum.each(entries, fn {eco, pkg, ver, findings, expires_at} ->
      insert_ets(eco, pkg, ver, findings, expires_at)
    end)

    Logger.info("CveCache warmed #{length(entries)} unexpired entries into ETS memory")
  rescue
    e ->
      Logger.debug("CveCache warm-up skipped: #{inspect(e)}")
      :ok
  end

  # ─── Internal helpers ─────────────────────────────────────────────────────

  defp partition_by_ets(queries, now) do
    Enum.reduce(queries, {[], []}, fn {name, version, eco, pkg} = q, {hits, misses} ->
      case lookup_ets(eco, pkg, version, now) do
        {:ok, findings} ->
          {[{{name, version}, findings} | hits], misses}

        :miss ->
          {hits, [q | misses]}
      end
    end)
  end

  defp lookup_ets(eco, pkg, ver, now) do
    if :ets.whereis(@table_name) != :undefined do
      case :ets.lookup(@table_name, {eco, pkg, ver}) do
        [{{^eco, ^pkg, ^ver}, findings, expires_at}] ->
          if DateTime.compare(expires_at, now) == :gt do
            {:ok, findings}
          else
            :ets.delete(@table_name, {eco, pkg, ver})
            :miss
          end

        _ ->
          :miss
      end
    else
      :miss
    end
  end

  defp insert_ets(eco, pkg, ver, findings, expires_at) do
    if :ets.whereis(@table_name) != :undefined do
      :ets.insert(@table_name, {{eco, pkg, ver}, findings, expires_at})
    end
  end

  defp partition_by_db(queries, now) do
    ecosystems = Enum.map(queries, fn {_n, _v, eco, _p} -> eco end) |> Enum.uniq()
    packages = Enum.map(queries, fn {_n, _v, _e, pkg} -> pkg end) |> Enum.uniq()
    versions = Enum.map(queries, fn {_n, ver, _e, _p} -> ver end) |> Enum.uniq()

    # Query DB for all matching records that are still unexpired
    records =
      from(c in CveCacheEntry,
        where:
          c.expires_at > ^now and
            c.ecosystem in ^ecosystems and
            c.package in ^packages and
            c.version in ^versions
      )
      |> Repo.all()
      |> Map.new(fn c -> {{c.ecosystem, c.package, c.version}, {c.findings, c.expires_at}} end)

    Enum.reduce(queries, {[], []}, fn {name, version, eco, pkg} = q, {hits, misses} ->
      key = {eco, pkg, version}

      case Map.get(records, key) do
        {findings, expires_at} ->
          {[{key, {name, version}, findings, expires_at} | hits], misses}

        nil ->
          {hits, [q | misses]}
      end
    end)
  rescue
    e ->
      Logger.debug("DB lookup in CveCache failed: #{inspect(e)}")
      {[], queries}
  end

  defp lookup_db(eco, pkg, ver, now) do
    case Repo.one(
           from(c in CveCacheEntry,
             where:
               c.ecosystem == ^eco and c.package == ^pkg and c.version == ^ver and
                 c.expires_at > ^now
           )
         ) do
      nil -> :miss
      entry -> {:ok, entry.findings, entry.expires_at}
    end
  rescue
    _ -> :miss
  end

  defp persist_db(eco, pkg, ver, findings, queried_at, expires_at) do
    attrs = %{
      ecosystem: eco,
      package: pkg,
      version: ver,
      findings: findings,
      queried_at: queried_at,
      expires_at: expires_at
    }

    %CveCacheEntry{}
    |> CveCacheEntry.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:findings, :queried_at, :expires_at, :updated_at]},
      conflict_target: [:ecosystem, :package, :version]
    )
  rescue
    e ->
      Logger.warning("Failed to persist CVE cache entry for #{eco}/#{pkg}@#{ver}: #{inspect(e)}")
      :ok
  end
end
