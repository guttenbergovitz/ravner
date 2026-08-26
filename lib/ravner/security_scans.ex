defmodule Ravner.SecurityScans do
  @moduledoc """
  The SecurityScans context.

  Manages on-demand security scans (Naabu, Nuclei, httpx) and their findings.
  """

  import Ecto.Query

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
    # Deep scan budget: httpx (~5m) + naabu (~5m) + nuclei (~8m) ≈ 18m worst case.
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

  @doc """
  Deletes all but the latest successful scan and any active scans for a domain.
  Ensures we only keep the "Current Posture" and the "Active Scan".
  """
  @spec prune_old_scans(integer()) :: {integer(), nil}
  def prune_old_scans(domain_id) do
    # Find IDs of scans to keep:
    # 1. Any currently running scan
    # 2. The most recent completed scan
    to_keep_ids =
      SecurityScan
      |> where(domain_id: ^domain_id)
      |> where([s], s.status in ["running", "completed"])
      |> order_by(desc: :inserted_at)
      |> limit(2)
      |> select([s], s.id)
      |> Repo.all()

    SecurityScan
    |> where(domain_id: ^domain_id)
    |> where([s], s.id not in ^to_keep_ids)
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
  """
  @spec create_findings_batch(integer(), [map()]) :: {integer(), nil}
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

    Repo.insert_all(ScanFinding, entries)
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
  Returns the most recent completed security scan for a domain (with findings
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
  Returns severity counts for the latest completed scan of a domain. Always
  returns the four buckets so the badge row stays consistent across domains.
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

    case latest_completed_scan(domain_id) do
      nil ->
        base

      %{findings: findings} when is_list(findings) ->
        Enum.reduce(findings, base, fn finding, acc ->
          case finding.severity do
            "critical" -> Map.update!(acc, :critical, &(&1 + 1))
            "high" -> Map.update!(acc, :high, &(&1 + 1))
            "medium" -> Map.update!(acc, :medium, &(&1 + 1))
            "low" -> Map.update!(acc, :low, &(&1 + 1))
            _ -> acc
          end
        end)

      _ ->
        base
    end
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
  Parses httpx JSON output into a list of finding attributes.
  """
  @spec parse_httpx_output(String.t()) :: [map()]
  def parse_httpx_output(raw_output) when is_binary(raw_output) do
    raw_output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, data} ->
          url = data["url"] || "unknown"
          status = data["status-code"]
          title = data["title"]
          tech = List.wrap(data["tech"])

          finding_title =
            if status do
              "HTTP #{status} — #{url}"
            else
              "Probe response — #{url}"
            end

          [
            %{
              severity: "info",
              title: finding_title,
              target: url,
              detail: %{
                "status-code" => status,
                "title" => title,
                "tech" => tech,
                "host" => data["host"],
                "ip" => data["ip"],
                "content-length" => data["content-length"],
                "webserver" => data["webserver"]
              }
            }
          ]

        _ ->
          []
      end
    end)
  end

  def parse_httpx_output(_), do: []

  @doc """
  Deletes a security scan and all its findings.
  """
  @spec delete_scan(SecurityScan.t()) :: {:ok, SecurityScan.t()} | {:error, Ecto.Changeset.t()}
  def delete_scan(%SecurityScan{} = scan) do
    Repo.delete(scan)
  end
end
