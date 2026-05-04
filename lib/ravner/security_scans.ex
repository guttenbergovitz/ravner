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
  """
  @spec list_scans_for_domain(integer()) :: [SecurityScan.t()]
  def list_scans_for_domain(domain_id) do
    SecurityScan
    |> where(domain_id: ^domain_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> Repo.all()
    |> Repo.preload(:findings)
  end

  @doc """
  Lists security scans for a domain as a stream-compatible query.
  """
  @spec scans_query_for_domain(integer()) :: Ecto.Query.t()
  def scans_query_for_domain(domain_id) do
    SecurityScan
    |> where(domain_id: ^domain_id)
    |> order_by(desc: :inserted_at, desc: :id)
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
