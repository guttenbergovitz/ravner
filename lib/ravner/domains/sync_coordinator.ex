defmodule Ravner.Domains.SyncCoordinator do
  @moduledoc """
  Coordinates bulk sync operations for domain-related data:
  DNS records, tech evidence, VCS technologies, and discovered URLs.

  Uses direct Ecto batch operations for performance on large datasets.
  """

  import Ecto.Query
  require Logger

  alias Ravner.Repo
  alias Ravner.Domains
  alias Ravner.Domains.{Domain, DnsRecord, TechEvidence, DiscoveredUrl}

  @doc """
  Replaces all DNS records for a domain with a newly discovered set.
  """
  @spec sync_dns_records(integer(), [map()]) :: {:ok, term()} | {:error, term()}
  def sync_dns_records(domain_id, records) when is_list(records) do
    run_transaction(:sync_dns_records, fn ->
      DnsRecord |> where(domain_id: ^domain_id) |> Repo.delete_all()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries =
        Enum.map(records, fn r ->
          %{
            domain_id: domain_id,
            type: r[:type] || r["type"],
            value: r[:value] || r["value"],
            ttl: r[:ttl] || r["ttl"],
            inserted_at: now,
            updated_at: now
          }
        end)

      if entries != [], do: Repo.insert_all(DnsRecord, entries)
    end)
  end

  @doc """
  Replaces all tech evidence for a domain with a newly discovered set.

  Uses raw Ecto batch operations to bypass Ash validation overhead on bulk crawler discoveries.
  """
  @spec sync_tech_evidence(integer(), [map()]) :: {:ok, term()} | {:error, term()}
  def sync_tech_evidence(domain_id, evidence) when is_list(evidence) do
    run_transaction(:sync_tech_evidence, fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries =
        Enum.map(evidence, fn e ->
          version = parse_version(e[:version] || e["version"])
          confidence = parse_confidence(e[:confidence] || e["confidence"])
          source = determine_source(e, confidence)

          %{
            domain_id: domain_id,
            name: e[:name] || e["name"] || e["App"] || "Unknown",
            version: version,
            source: source,
            confidence: confidence,
            inserted_at: now,
            updated_at: now
          }
        end)

      sources = Enum.uniq(Enum.map(entries, & &1.source))

      if sources != [] do
        TechEvidence
        |> where([te], te.domain_id == ^domain_id and te.source in ^sources)
        |> Repo.delete_all()

        Repo.insert_all(TechEvidence, entries)
      end
    end)
  end

  @doc """
  Merges VCS-discovered technologies into a domain's tech evidence and tech stack.
  Replaces previous VCS evidence while preserving HTTP crawler discoveries.
  """
  @spec merge_vcs_tech_evidence(integer(), [String.t()], String.t() | atom()) ::
          {:ok, term()} | {:error, term()}
  def merge_vcs_tech_evidence(domain_id, technologies, provider \\ "bitbucket") do
    provider_str = to_string(provider)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    run_transaction(:merge_vcs_tech_evidence, fn ->
      # Remove previous VCS-derived evidence
      TechEvidence
      |> where([te], te.domain_id == ^domain_id and like(te.source, "vcs%"))
      |> Repo.delete_all()

      # Insert new VCS evidence
      entries =
        Enum.map(technologies, fn tech ->
          %{
            domain_id: domain_id,
            name: tech,
            source: "vcs:#{provider_str}",
            confidence: 100,
            inserted_at: now,
            updated_at: now
          }
        end)

      if entries != [], do: Repo.insert_all(TechEvidence, entries)

      # Merge into domain_metadata.tech_stack
      case Domains.get_domain_metadata(domain_id) do
        nil ->
          Domains.upsert_domain_metadata(domain_id, %{tech_stack: technologies})

        metadata ->
          current = metadata.tech_stack || []
          updated = Enum.uniq(current ++ technologies)
          Domains.upsert_domain_metadata(domain_id, %{tech_stack: updated})
      end
    end)
  end

  @doc """
  Collects technologies from all repositories linked or accessible to a domain
  and updates the domain's tech evidence and metadata tech stack.
  """
  @spec sync_all_vcs_tech_evidence_for_domain(integer()) :: {:ok, term()} | {:error, term()}
  def sync_all_vcs_tech_evidence_for_domain(domain_id) do
    case Repo.get(Domain, domain_id) do
      nil ->
        {:error, :domain_not_found}

      domain ->
        repos = Ravner.Inventory.list_all_repositories_for_domain(domain)

        all_techs =
          repos
          |> Enum.flat_map(&extract_technologies/1)
          |> Enum.uniq()

        provider =
          case repos do
            [first | _] -> first.provider || "bitbucket"
            _ -> "bitbucket"
          end

        merge_vcs_tech_evidence(domain_id, all_techs, provider)
    end
  end

  @doc """
  Replaces all discovered URLs for a domain with a newly discovered set.

  Direct batch write capable of handling thousands of crawled URLs
  without BEAM memory ballooning.
  """
  @spec sync_discovered_urls(integer(), [map()]) :: {:ok, term()} | {:error, term()}
  def sync_discovered_urls(domain_id, urls) when is_list(urls) do
    run_transaction(:sync_discovered_urls, fn ->
      DiscoveredUrl |> where(domain_id: ^domain_id) |> Repo.delete_all()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries =
        Enum.map(urls, fn u ->
          %{
            domain_id: domain_id,
            url: u[:url] || u["url"],
            status: u[:status] || u["status"],
            content_type: u[:content_type] || u["content_type"],
            source: u[:source] || u["source"],
            inserted_at: now,
            updated_at: now
          }
        end)

      if entries != [], do: Repo.insert_all(DiscoveredUrl, entries)
    end)
  end

  # ─── Private Helpers ────────────────────────────────────────────────────────

  defp run_transaction(operation, fun) do
    case Repo.transaction(fun) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} = error ->
        Logger.error("Domain sync transaction failed",
          operation: operation,
          reason: inspect(reason)
        )

        error
    end
  end

  defp parse_version(v) when is_binary(v) do
    trimmed = String.trim(v)
    if trimmed == "", do: nil, else: trimmed
  end

  defp parse_version(_), do: nil

  defp parse_confidence(c) when is_integer(c), do: c

  defp parse_confidence(c) when is_binary(c) do
    case Integer.parse(c) do
      {val, _} -> val
      _ -> nil
    end
  end

  defp parse_confidence(_), do: nil

  defp determine_source(e, confidence) do
    cond do
      e[:implied] == true or e["implied"] == true ->
        "wappalyzer:implied"

      is_binary(e[:source]) and e[:source] != "" ->
        e[:source]

      is_binary(e["source"]) and e["source"] != "" ->
        e["source"]

      confidence == 50 ->
        "wappalyzer:implied"

      true ->
        "wappalyzer:direct"
    end
  end

  defp extract_technologies(repo) do
    case repo.technology do
      tech_str when is_binary(tech_str) and tech_str != "" ->
        tech_str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end
end
