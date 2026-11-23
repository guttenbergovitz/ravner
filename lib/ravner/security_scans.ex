defmodule Ravner.SecurityScans do
  @moduledoc """
  The SecurityScans context.

  Manages on-demand security scans (Naabu, Nuclei) and their findings.
  """

  require Logger

  import Ecto.Query

  alias Ravner.Domains.Domain
  alias Ravner.Repo
  alias Ravner.SecurityScans.ScanFinding
  alias Ravner.SecurityScans.SecurityScan

  @doc """
  Creates a new security scan.
  """
  @spec create_scan(map()) :: {:ok, SecurityScan.t()} | {:error, Ecto.Changeset.t()}
  def create_scan(attrs) do
    %SecurityScan{}
    |> SecurityScan.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a security scan.
  """
  @spec update_scan(SecurityScan.t(), map()) ::
          {:ok, SecurityScan.t()} | {:error, Ecto.Changeset.t()}
  def update_scan(%SecurityScan{} = scan, attrs) do
    scan
    |> SecurityScan.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets a single security scan, raising if not found.
  """
  @spec get_scan!(integer()) :: SecurityScan.t()
  def get_scan!(id) do
    SecurityScan
    |> Repo.get!(id)
    |> Repo.preload(:findings)
  end

  @doc """
  Lists security scans for a domain, ordered by most recent first.
  In "latest posture" mode, we primarily care about the most recent results.
  """
  @spec list_scans_for_domain(integer()) :: [SecurityScan.t()]
  def list_scans_for_domain(domain_id) do
    scans_query_for_domain(domain_id)
    |> Repo.all()
    |> Repo.preload(:findings)
  end

  @doc """
  Lists security scans for a domain as a stream-compatible query.
  Limits to the latest few scans to keep the UI clean.
  """
  @spec scans_query_for_domain(integer()) :: Ecto.Query.t()
  def scans_query_for_domain(domain_id) do
    SecurityScan
    |> where(domain_id: ^domain_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(5)
  end

  @doc """
  Marks scans that have been running for too long as failed.
  """
  @spec cleanup_stale_scans() :: {integer(), nil}
  def cleanup_stale_scans do
    # Deep scan budget: HTTP probe (~30s) + naabu (~5m) + nuclei (~8m) ≈ 14m worst case.
    # Watchdog gives a small grace window on top of that before forcing failure.
    timeout_ago = DateTime.add(DateTime.utc_now(), -20, :minute)

    SecurityScan
    |> where([s], s.status == "running" and s.inserted_at < ^timeout_ago)
    |> Repo.update_all(
      set: [
        status: "failed",
        error_message: "Scan timed out (running for > 20 minutes)",
        completed_at: DateTime.utc_now(),
        progress: 100
      ]
    )
  end

  @doc """
  Forces all running scans for a domain to fail.
  Used when a user wants to manually clear "hanging" scans.
  """
  @spec clear_running_scans(integer()) :: {integer(), nil}
  def clear_running_scans(domain_id) do
    SecurityScan
    |> where(domain_id: ^domain_id, status: "running")
    |> Repo.update_all(
      set: [
        status: "failed",
        error_message: "Manually cancelled",
        completed_at: DateTime.utc_now(),
        progress: 100
      ]
    )
  end

  @security_tools ["security_scan", "light_scan", "naabu", "nuclei", "repo_sca"]
  @breach_tools ["breach_lookup"]

  @doc """
  Deletes older completed scans while ensuring recent scans for each tool family
  (vulnerability scanners and breach lookups) and active running scans are preserved.

  Uses a single atomic query with subqueries to avoid race conditions where a scan
  might complete between the SELECT and DELETE operations.
  """
  @spec prune_old_scans(integer()) :: {integer(), nil}
  def prune_old_scans(domain_id) do
    # Subquery: IDs of running scans (protected from deletion)
    running_subquery =
      SecurityScan
      |> where(domain_id: ^domain_id, status: "running")
      |> select([s], s.id)

    # Subquery: top 5 recent completed security scans
    security_subquery =
      SecurityScan
      |> where(domain_id: ^domain_id, status: "completed")
      |> where([s], s.tool in @security_tools)
      |> order_by(desc: :inserted_at, desc: :id)
      |> limit(5)
      |> select([s], s.id)

    # Subquery: top 5 recent completed breach scans
    breach_subquery =
      SecurityScan
      |> where(domain_id: ^domain_id, status: "completed")
      |> where([s], s.tool in @breach_tools)
      |> order_by(desc: :inserted_at, desc: :id)
      |> limit(5)
      |> select([s], s.id)

    # Single atomic delete: exclude IDs from all three subqueries
    SecurityScan
    |> where(domain_id: ^domain_id)
    |> where([s], s.id not in subquery(running_subquery))
    |> where([s], s.id not in subquery(security_subquery))
    |> where([s], s.id not in subquery(breach_subquery))
    |> Repo.delete_all()
  end

  @doc """
  Creates a scan finding.
  """
  @spec create_finding(map()) :: {:ok, ScanFinding.t()} | {:error, Ecto.Changeset.t()}
  def create_finding(attrs) do
    %ScanFinding{}
    |> ScanFinding.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Inserts a batch of findings efficiently.

  Returns `{:ok, count}` on success or `{:error, reason}` on failure.
  Empty findings list returns `{:ok, 0}` without touching the database.
  """
  @spec create_findings_batch(integer(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def create_findings_batch(_scan_id, []), do: {:ok, 0}

  def create_findings_batch(scan_id, findings) when is_list(findings) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(findings, fn f ->
        %{
          security_scan_id: scan_id,
          severity: f[:severity] || "info",
          title: f[:title],
          target: f[:target],
          detail: f[:detail],
          inserted_at: now,
          updated_at: now
        }
      end)

    case Repo.insert_all(ScanFinding, entries) do
      {count, _} when is_integer(count) ->
        {:ok, count}

      other ->
        Logger.error("Batch insert findings failed for scan #{scan_id}: #{inspect(other)}")
        {:error, :insert_failed}
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.error("Batch insert findings DB error for scan #{scan_id}: #{inspect(e)}")
      {:error, {:db_error, e}}
  end

  @doc """
  Lists findings for a security scan.
  """
  @spec list_findings_for_scan(integer()) :: [ScanFinding.t()]
  def list_findings_for_scan(scan_id) do
    ScanFinding
    |> where(security_scan_id: ^scan_id)
    |> order_by(desc: :severity, asc: :title)
    |> Repo.all()
  end

  @doc """
  Returns the most recent completed security or breach scan for a domain (with findings
  preloaded), or `nil` when no completed scan exists yet.
  """
  @spec latest_completed_scan(integer()) :: SecurityScan.t() | nil
  def latest_completed_scan(domain_id) do
    SecurityScan
    |> where(domain_id: ^domain_id, status: "completed")
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(1)
    |> Repo.one()
    |> maybe_preload_findings()
  end

  @doc """
  Returns the most recent completed vulnerability/posture scan for a domain (excluding
  standalone dark web breach lookups), with findings preloaded.
  """
  @spec latest_security_scan(integer()) :: SecurityScan.t() | nil
  def latest_security_scan(domain_id) do
    SecurityScan
    |> where(domain_id: ^domain_id, status: "completed")
    |> where([s], s.tool in @security_tools)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(1)
    |> Repo.one()
    |> maybe_preload_findings()
  end

  @doc """
  Returns the most recent completed dark web breach scan for a domain, with findings preloaded.
  """
  @spec latest_breach_scan(integer()) :: SecurityScan.t() | nil
  def latest_breach_scan(domain_id) do
    SecurityScan
    |> where(domain_id: ^domain_id, status: "completed")
    |> where([s], s.tool in @breach_tools)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(1)
    |> Repo.one()
    |> maybe_preload_findings()
  end

  @doc """
  Returns combined findings from the latest security scan and latest breach scan for a domain,
  deduplicated and ordered by severity.
  """
  @spec list_all_active_findings_for_domain(integer()) :: [ScanFinding.t()]
  def list_all_active_findings_for_domain(domain_id) do
    sec_scan = latest_security_scan(domain_id)
    breach_scan = latest_breach_scan(domain_id)

    sec_findings = if sec_scan && is_list(sec_scan.findings), do: sec_scan.findings, else: []

    breach_findings =
      if breach_scan && is_list(breach_scan.findings), do: breach_scan.findings, else: []

    (sec_findings ++ breach_findings)
    |> Enum.sort_by(fn f ->
      case f.severity do
        "critical" -> 0
        "high" -> 1
        "medium" -> 2
        "low" -> 3
        _ -> 4
      end
    end)
  end

  @doc """
  Returns the most recent running security scan for a domain, or `nil`.
  """
  @spec running_scan(integer()) :: SecurityScan.t() | nil
  def running_scan(domain_id) do
    SecurityScan
    |> where(domain_id: ^domain_id, status: "running")
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns the most recent failed security scan for a domain, or `nil`. Used
  when there is no completed scan yet but a recent failure should still surface.
  """
  @spec latest_failed_scan(integer()) :: SecurityScan.t() | nil
  def latest_failed_scan(domain_id) do
    SecurityScan
    |> where(domain_id: ^domain_id, status: "failed")
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns severity counts for active findings across the domain's latest security
  and breach scans. Always returns the four buckets so the badge row stays consistent.
  """
  @spec severity_counts_for_domain(integer()) ::
          %{
            critical: non_neg_integer(),
            high: non_neg_integer(),
            medium: non_neg_integer(),
            low: non_neg_integer()
          }
  def severity_counts_for_domain(domain_id) do
    base = %{critical: 0, high: 0, medium: 0, low: 0}
    findings = list_all_active_findings_for_domain(domain_id)

    Enum.reduce(findings, base, fn finding, acc ->
      case finding.severity do
        "critical" -> Map.update!(acc, :critical, &(&1 + 1))
        "high" -> Map.update!(acc, :high, &(&1 + 1))
        "medium" -> Map.update!(acc, :medium, &(&1 + 1))
        "low" -> Map.update!(acc, :low, &(&1 + 1))
        _ -> acc
      end
    end)
  end

  defp maybe_preload_findings(nil), do: nil

  defp maybe_preload_findings(%SecurityScan{} = scan),
    do: Repo.preload(scan, [:findings], in_parallel: false)

  @doc """
  Counts findings grouped by severity for a given scan.
  """
  @spec count_findings_by_severity(integer()) :: %{String.t() => integer()}
  def count_findings_by_severity(scan_id) do
    ScanFinding
    |> where(security_scan_id: ^scan_id)
    |> group_by([f], f.severity)
    |> select([f], {f.severity, count(f.id)})
    |> Repo.all()
    |> Map.new(fn {severity, count} -> {severity || "info", count} end)
  end

  @doc """
  Parses Naabu JSON output into a list of finding attributes.
  """
  @spec parse_naabu_output(String.t()) :: [map()]
  def parse_naabu_output(raw_output) when is_binary(raw_output) do
    raw_output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"port" => port, "ip" => ip} = data} ->
          host = Map.get(data, "host", ip)

          [
            %{
              severity: "info",
              title: "Open port #{port} on #{host}",
              target: "#{host}:#{port}",
              detail: %{
                "port" => port,
                "ip" => ip,
                "host" => host
              }
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.target)
  end

  def parse_naabu_output(_), do: []

  @doc """
  Parses Nuclei JSONL output into a list of finding attributes.
  """
  @spec parse_nuclei_output(String.t()) :: [map()]
  def parse_nuclei_output(raw_output) when is_binary(raw_output) do
    raw_output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, data} ->
          severity = String.downcase(Map.get(data, "info", %{})["severity"] || "info")

          [
            %{
              severity: severity,
              title: get_in(data, ["info", "name"]) || "Unknown finding",
              target: data["host"] || data["matched-at"] || "unknown",
              detail: %{
                "template-id" => data["template-id"],
                "template" => get_in(data, ["info", "tags"]),
                "matched-at" => data["matched-at"],
                "curl-command" => data["curl-command"],
                "description" => get_in(data, ["info", "description"]),
                "reference" => get_in(data, ["info", "reference"]),
                "type" => data["type"],
                "ip" => data["ip"]
              }
            }
          ]

        _ ->
          []
      end
    end)
  end

  def parse_nuclei_output(_), do: []

  @doc """
  Parses Lonkero JSON array output into a list of finding attributes.
  """
  @spec parse_lonkero_output(String.t()) :: [map()]
  def parse_lonkero_output(raw_output) when is_binary(raw_output) do
    case Jason.decode(raw_output) do
      {:ok, items} when is_list(items) ->
        Enum.flat_map(items, fn item ->
          severity = String.downcase(item["severity"] || "info")

          severity =
            if severity in ["critical", "high", "medium", "low", "info"],
              do: severity,
              else: "info"

          [
            %{
              severity: severity,
              title: item["type"] || "Unknown finding",
              target: item["url"] || "unknown",
              detail: %{
                "confidence" => item["confidence"],
                "category" => item["category"],
                "cwe" => item["cwe"],
                "evidence" => item["evidence"],
                "timestamp" => item["timestamp"]
              }
            }
          ]
        end)

      _ ->
        []
    end
  end

  def parse_lonkero_output(_), do: []

  @doc """
  Deletes a security scan and all its findings.
  """
  @spec delete_scan(SecurityScan.t()) :: {:ok, SecurityScan.t()} | {:error, Ecto.Changeset.t()}
  def delete_scan(%SecurityScan{} = scan) do
    Repo.delete(scan)
  end

  @doc """
  Computes portfolio-wide security posture and threat intelligence summary.
  Aggregates active findings across each domain's latest completed security
  and breach scans.
  """
  @spec portfolio_security_summary(keyword()) :: %{
          scanned_domains_count: non_neg_integer(),
          critical: non_neg_integer(),
          high: non_neg_integer(),
          medium: non_neg_integer(),
          low: non_neg_integer(),
          info: non_neg_integer(),
          total_findings: non_neg_integer(),
          domains_at_risk_count: non_neg_integer(),
          exposed_secrets_count: non_neg_integer(),
          breach_findings_count: non_neg_integer(),
          top_vulnerable_domains: [map()],
          recent_critical_findings: [map()]
        }
  def portfolio_security_summary(opts \\ []) do
    scannable_states = Domain.scannable_states()

    domain_filter =
      cond do
        brand_id = opts[:brand_id] ->
          from(d in Domain,
            where: d.brand_id == ^brand_id and d.lifecycle_state in ^scannable_states,
            select: d.id
          )

        org_id = opts[:organization_id] ->
          from(d in Domain,
            where: d.organization_id == ^org_id and d.lifecycle_state in ^scannable_states,
            select: d.id
          )

        true ->
          from(d in Domain,
            where: d.lifecycle_state in ^scannable_states,
            select: d.id
          )
      end

    sec_query =
      from(s in SecurityScan,
        where: s.status == "completed" and s.tool in @security_tools,
        distinct: s.domain_id,
        order_by: [asc: s.domain_id, desc: s.inserted_at, desc: s.id],
        select: s.id
      )

    sec_query =
      if domain_filter,
        do: where(sec_query, [s], s.domain_id in subquery(domain_filter)),
        else: sec_query

    latest_sec_scan_ids = Repo.all(sec_query)

    breach_query =
      from(s in SecurityScan,
        where: s.status == "completed" and s.tool in @breach_tools,
        distinct: s.domain_id,
        order_by: [asc: s.domain_id, desc: s.inserted_at, desc: s.id],
        select: s.id
      )

    breach_query =
      if domain_filter,
        do: where(breach_query, [s], s.domain_id in subquery(domain_filter)),
        else: breach_query

    latest_breach_scan_ids = Repo.all(breach_query)

    all_active_scan_ids = Enum.uniq(latest_sec_scan_ids ++ latest_breach_scan_ids)

    default_summary = %{
      scanned_domains_count: 0,
      critical: 0,
      high: 0,
      medium: 0,
      low: 0,
      info: 0,
      total_findings: 0,
      domains_at_risk_count: 0,
      exposed_secrets_count: 0,
      breach_findings_count: 0,
      top_vulnerable_domains: [],
      recent_critical_findings: []
    }

    if all_active_scan_ids == [] do
      default_summary
    else
      scanned_domains_count =
        from(s in SecurityScan,
          where: s.id in ^all_active_scan_ids,
          select: count(s.domain_id, :distinct)
        )
        |> Repo.one() || 0

      severity_counts =
        from(f in ScanFinding,
          where: f.security_scan_id in ^all_active_scan_ids,
          group_by: f.severity,
          select: {f.severity, count(f.id)}
        )
        |> Repo.all()
        |> Map.new(fn {sev, cnt} -> {String.downcase(sev || "info"), cnt} end)

      critical = Map.get(severity_counts, "critical", 0)
      high = Map.get(severity_counts, "high", 0)
      medium = Map.get(severity_counts, "medium", 0)
      low = Map.get(severity_counts, "low", 0)
      info = Map.get(severity_counts, "info", 0)
      total_findings = critical + high + medium + low + info

      domains_at_risk_count =
        from(f in ScanFinding,
          join: s in assoc(f, :security_scan),
          where:
            f.security_scan_id in ^all_active_scan_ids and f.severity in ["critical", "high"],
          select: count(s.domain_id, :distinct)
        )
        |> Repo.one() || 0

      exposed_secrets_count =
        from(f in ScanFinding,
          where:
            f.security_scan_id in ^all_active_scan_ids and
              (ilike(f.title, ^"%exposed%") or ilike(f.title, ^"%secret%") or
                 ilike(f.title, ^"%.env%") or ilike(f.title, ^"%.git%")),
          select: count(f.id)
        )
        |> Repo.one() || 0

      breach_findings_count =
        if latest_breach_scan_ids != [] do
          from(f in ScanFinding,
            where: f.security_scan_id in ^latest_breach_scan_ids,
            select: count(f.id)
          )
          |> Repo.one() || 0
        else
          0
        end

      top_vulnerable_domains =
        from(f in ScanFinding,
          join: s in assoc(f, :security_scan),
          join: d in assoc(s, :domain),
          where:
            f.security_scan_id in ^all_active_scan_ids and
              f.severity in ["critical", "high", "medium"],
          group_by: [d.id, d.name],
          select: %{
            domain_id: d.id,
            domain_name: d.name,
            critical_count: count(fragment("CASE WHEN ? = 'critical' THEN 1 END", f.severity)),
            high_count: count(fragment("CASE WHEN ? = 'high' THEN 1 END", f.severity)),
            medium_count: count(fragment("CASE WHEN ? = 'medium' THEN 1 END", f.severity)),
            risk_weight:
              sum(
                fragment(
                  "CASE WHEN ? = 'critical' THEN 10 WHEN ? = 'high' THEN 5 ELSE 1 END",
                  f.severity,
                  f.severity
                )
              )
          },
          order_by: [
            desc:
              sum(
                fragment(
                  "CASE WHEN ? = 'critical' THEN 10 WHEN ? = 'high' THEN 5 ELSE 1 END",
                  f.severity,
                  f.severity
                )
              )
          ],
          limit: 10
        )
        |> Repo.all()

      recent_critical_findings =
        from(f in ScanFinding,
          join: s in assoc(f, :security_scan),
          join: d in assoc(s, :domain),
          where:
            f.security_scan_id in ^all_active_scan_ids and
              f.severity in ["critical", "high"],
          order_by: [desc: f.inserted_at, desc: f.id],
          limit: 8,
          select: %{
            id: f.id,
            title: f.title,
            severity: f.severity,
            target: f.target,
            domain_id: d.id,
            domain_name: d.name,
            inserted_at: f.inserted_at
          }
        )
        |> Repo.all()

      %{
        scanned_domains_count: scanned_domains_count,
        critical: critical,
        high: high,
        medium: medium,
        low: low,
        info: info,
        total_findings: total_findings,
        domains_at_risk_count: domains_at_risk_count,
        exposed_secrets_count: exposed_secrets_count,
        breach_findings_count: breach_findings_count,
        top_vulnerable_domains: top_vulnerable_domains,
        recent_critical_findings: recent_critical_findings
      }
    end
  end

  # ─── Repository Vulnerabilities (SCA) ────────────────────────────────────────

  @doc """
  Lists all vulnerabilities detected for a specific project repository,
  ordered by severity (critical first) then package name.
  """
  @spec list_repository_vulnerabilities(integer()) ::
          [Ravner.Scans.ProjectRepositoryVulnerability.t()]
  def list_repository_vulnerabilities(repository_id) do
    alias Ravner.Scans.ProjectRepositoryVulnerability

    ProjectRepositoryVulnerability
    |> where([v], v.project_repository_id == ^repository_id)
    |> order_by([v], [
      fragment(
        "CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END",
        v.severity
      ),
      asc: v.package_name
    ])
    |> Repo.all()
  end

  @doc """
  Lists all vulnerabilities detected across all repositories linked to a domain.
  """
  @spec list_vulnerabilities_for_domain_repositories(integer()) ::
          [Ravner.Scans.ProjectRepositoryVulnerability.t()]
  def list_vulnerabilities_for_domain_repositories(domain_id) do
    alias Ravner.Inventory.ProjectRepository
    alias Ravner.Scans.ProjectRepositoryVulnerability

    from(v in ProjectRepositoryVulnerability,
      join: r in ProjectRepository,
      on: v.project_repository_id == r.id,
      where: r.domain_id == ^domain_id,
      preload: [project_repository: r],
      order_by: [
        fragment(
          "CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END",
          v.severity
        ),
        asc: v.package_name
      ]
    )
    |> Repo.all()
  end
end
