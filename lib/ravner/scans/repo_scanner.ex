defmodule Ravner.Scans.RepoScanner do
  @moduledoc """
  Repository Software Composition Analysis (SCA) scanner engine.

  Fetches lockfiles and package manifests from connected VCS repositories
  (Bitbucket, GitHub, GitLab), parses dependency graphs via `ManifestParser`,
  and correlates them with Google OSV.dev via `CveCache`.

  Results are persisted in `project_repository_vulnerabilities`, roll-up counters
  are updated on `project_repositories`, and if attached to a domain, a corresponding
  `SecurityScan` with tool `repo_sca` is registered in `security_scans` / `scan_findings`.
  """

  require Logger

  import Ecto.Query

  alias Ravner.Integrations.VCS
  alias Ravner.Inventory.ProjectRepository
  alias Ravner.Repo
  alias Ravner.Scans.CveCache
  alias Ravner.Scans.CveLookup
  alias Ravner.Scans.ManifestParser
  alias Ravner.Scans.ProjectRepositoryVulnerability
  alias Ravner.SecurityScans

  @doc """
  Runs dependency vulnerability scan for a given repository.
  """
  @spec scan_repository(ProjectRepository.t() | integer(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def scan_repository(repo_or_id, opts \\ [])

  def scan_repository(repo_id, opts) when is_integer(repo_id) do
    case Repo.get(ProjectRepository, repo_id) do
      nil -> {:error, "Repository #{repo_id} not found"}
      repo -> scan_repository(repo, opts)
    end
  end

  def scan_repository(%ProjectRepository{} = repo, opts) do
    provider = repo.provider || VCS.detect_provider_from_url(repo.url)
    repo_slug = repo.external_id || VCS.extract_slug_from_url(repo.url)
    branch = repo.default_branch || "main"

    cond do
      is_nil(repo_slug) ->
        mark_scan_error(repo, "Unable to determine repository slug from URL '#{repo.url}'")
        {:error, "Unable to determine repository slug from URL"}

      true ->
        creds = VCS.resolve_credentials(provider)

        if is_nil(creds) do
          mark_scan_error(
            repo,
            "No active integration credentials configured for #{provider}"
          )

          {:error, "No active integration credentials configured for #{provider}"}
        else
          do_scan(repo, provider, repo_slug, branch, creds, opts)
        end
    end
  end

  @doc """
  Scans all repositories associated with a domain.
  """
  @spec scan_domain_repositories(integer(), keyword()) :: {:ok, [map()]}
  def scan_domain_repositories(domain_id, opts \\ []) do
    repos =
      ProjectRepository
      |> where([r], r.domain_id == ^domain_id)
      |> Repo.all()

    results =
      Enum.map(repos, fn repo ->
        case scan_repository(repo, opts) do
          {:ok, res} -> res
          {:error, reason} -> %{repository: repo, error: reason}
        end
      end)

    {:ok, results}
  end

  @doc """
  Fetches and parses manifest dependencies for a given repository.
  Returns `{:ok, [{package_name, version, ecosystem, manifest_file}]}` or `{:error, reason}`.
  """
  @spec fetch_manifest_dependencies(ProjectRepository.t() | integer()) ::
          {:ok, [{String.t(), String.t(), String.t(), String.t()}]} | {:error, String.t()}
  def fetch_manifest_dependencies(repo_or_id)

  def fetch_manifest_dependencies(repo_id) when is_integer(repo_id) do
    case Repo.get(ProjectRepository, repo_id) do
      nil -> {:error, "Repository #{repo_id} not found"}
      repo -> fetch_manifest_dependencies(repo)
    end
  end

  def fetch_manifest_dependencies(%ProjectRepository{} = repo) do
    provider = repo.provider || VCS.detect_provider_from_url(repo.url)
    repo_slug = repo.external_id || VCS.extract_slug_from_url(repo.url)
    branch = repo.default_branch || "main"

    cond do
      is_nil(repo_slug) ->
        {:error, "Unable to determine repository slug from URL"}

      true ->
        case VCS.resolve_credentials(provider) do
          nil ->
            {:error, "No active integration credentials configured for #{provider}"}

          creds ->
            {:ok, fetch_extracted_dependencies(provider, repo_slug, branch, creds)}
        end
    end
  end

  # ─── Internal Scan Pipeline ──────────────────────────────────────────────────

  defp fetch_extracted_dependencies(provider, repo_slug, branch, creds) do
    manifest_files = ManifestParser.known_manifest_files()

    Enum.reduce_while(manifest_files, {:ok, []}, fn filename, {:ok, acc} ->
      case VCS.fetch_file(provider, repo_slug, filename, branch, creds) do
        {:ok, content} when is_binary(content) ->
          parsed =
            Enum.map(ManifestParser.parse(filename, content), fn {pkg, ver, eco} ->
              {pkg, ver, eco, filename}
            end)

          {:cont, {:ok, acc ++ parsed}}

        {:error, reason} ->
          if is_binary(reason) and String.contains?(reason, "not found") do
            {:cont, {:ok, acc}}
          else
            {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, dependencies} ->
        {:ok, Enum.uniq_by(dependencies, fn {pkg, ver, eco, _file} -> {pkg, ver, eco} end)}

      error ->
        error
    end
  end

  defp do_scan(repo, provider, repo_slug, branch, creds, opts) do
    scan_started_at = System.monotonic_time(:millisecond)
    # Mark status as scanning
    set_scan_status(repo.id, "scanning")

    # 1. Discover and fetch dependencies from manifest files
    extracted_deps_result = fetch_extracted_dependencies(provider, repo_slug, branch, creds)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case extracted_deps_result do
      {:error, reason} ->
        mark_scan_error(repo, reason)
        {:error, reason}

      {:ok, []} ->
        # Clean state: no dependencies found or all lockfiles empty
        clear_existing_vulnerabilities(repo.id)

        updated_repo =
          update_repo_scan_results(repo.id, %{
            scan_status: "clean",
            last_scanned_at: now,
            vulnerability_count: 0,
            critical_vuln_count: 0,
            high_vuln_count: 0,
            medium_vuln_count: 0,
            low_vuln_count: 0
          })

        # Clean up or record clean scan for domain if attached
        maybe_record_domain_sca_scan(updated_repo, [])

        # Emit synthetic SCA telemetry event
        duration_ms = System.monotonic_time(:millisecond) - scan_started_at

        Ravner.Telemetry.Synthetic.emit_sca_scan(
          %{
            duration_ms: duration_ms,
            vulnerability_count: 0,
            critical_count: 0,
            high_count: 0
          },
          %{
            "vcs.provider" => to_string(provider),
            "vcs.repository.name" => repo_slug,
            "vcs.repository.url" => repo.url,
            "ravner.project_id" => repo.project_id,
            "ravner.domain_id" => repo.domain_id
          }
        )

        # 2. Scan repository configuration files for secrets & credentials
        Ravner.Scans.SecretsScanner.scan_repository_files(
          repo,
          provider,
          repo_slug,
          branch,
          creds,
          opts
        )

        final_repo = Repo.get!(ProjectRepository, repo.id)

        {:ok, %{repository: final_repo, vulnerabilities: []}}

      {:ok, extracted_deps} ->
        # 2. Correlate against OSV.dev via CveCache
        queries =
          Enum.map(extracted_deps, fn {pkg, ver, eco, _file} ->
            {pkg, ver, eco, pkg}
          end)

        vulns_by_key = CveCache.fetch_batch(queries, &CveLookup.fetch_osv/1)

        if match?({:error, _}, vulns_by_key) do
          {:error, reason} = vulns_by_key
          mark_scan_error(repo, reason)
          {:error, reason}
        else
          # 3. Extract actionable vulnerabilities
          vulnerability_attrs =
            Enum.flat_map(extracted_deps, fn {pkg, ver, eco, manifest_file} ->
              vulns_by_key
              |> Map.get({pkg, ver}, [])
              |> Enum.filter(&CveLookup.actionable_vuln?/1)
              |> Enum.map(
                &build_vulnerability_record(&1, pkg, ver, eco, manifest_file, repo.id, now)
              )
            end)

          # 4. Persist to project_repository_vulnerabilities
          clear_existing_vulnerabilities(repo.id)

          if vulnerability_attrs != [] do
            Repo.insert_all(ProjectRepositoryVulnerability, vulnerability_attrs)
          end

          # 5. Compute stats and update project_repository
          total = length(vulnerability_attrs)
          critical = Enum.count(vulnerability_attrs, &(&1.severity == "critical"))
          high = Enum.count(vulnerability_attrs, &(&1.severity == "high"))
          medium = Enum.count(vulnerability_attrs, &(&1.severity == "medium"))
          low = Enum.count(vulnerability_attrs, &(&1.severity == "low"))
          status = if total > 0, do: "vulnerable", else: "clean"

          updated_repo =
            update_repo_scan_results(repo.id, %{
              scan_status: status,
              last_scanned_at: now,
              vulnerability_count: total,
              critical_vuln_count: critical,
              high_vuln_count: high,
              medium_vuln_count: medium,
              low_vuln_count: low
            })

          # 6. Record domain security scan if repo is attached to a domain
          maybe_record_domain_sca_scan(updated_repo, vulnerability_attrs)

          if updated_repo.domain_id do
            Ravner.Governance.RiskScore.recalculate_for_domain(updated_repo.domain_id)
          end

          # 7. Dispatch security alerts if critical CVEs were detected
          if critical > 0 do
            Ravner.Notifications.dispatch_critical_vulnerabilities(
              updated_repo,
              vulnerability_attrs
            )
          end

          # Emit synthetic SCA telemetry event
          duration_ms = System.monotonic_time(:millisecond) - scan_started_at

          Ravner.Telemetry.Synthetic.emit_sca_scan(
            %{
              duration_ms: duration_ms,
              vulnerability_count: total,
              critical_count: critical,
              high_count: high
            },
            %{
              "vcs.provider" => to_string(provider),
              "vcs.repository.name" => repo_slug,
              "vcs.repository.url" => repo.url,
              "ravner.project_id" => repo.project_id,
              "ravner.domain_id" => repo.domain_id
            }
          )

          # 8. Scan repository configuration files for secrets & credentials
          Ravner.Scans.SecretsScanner.scan_repository_files(
            repo,
            provider,
            repo_slug,
            branch,
            creds,
            opts
          )

          final_repo = Repo.get!(ProjectRepository, repo.id)

          {:ok, %{repository: final_repo, vulnerabilities: vulnerability_attrs}}
        end
    end
  rescue
    e ->
      Logger.error("Repository scan failed for #{repo.url}: #{inspect(e)}")
      mark_scan_error(repo, Exception.message(e))
      {:error, Exception.message(e)}
  end

  defp build_vulnerability_record(vuln, pkg, ver, eco, manifest_file, repo_id, now) do
    id = vuln["id"] || "OSV-UNKNOWN"

    cve_id =
      Enum.find(vuln["aliases"] || [], &String.starts_with?(&1, "CVE-")) ||
        case Regex.run(~r/(\d{4}-\d+)/, id) do
          [_, num] -> "CVE-#{num}"
          _ -> id
        end

    summary =
      cond do
        vuln["summary"] && vuln["summary"] != "" ->
          vuln["summary"]

        vuln["details"] && vuln["details"] != "" ->
          vuln["details"] |> String.split("\n") |> hd() |> String.slice(0, 160)

        true ->
          "Vulnerability in #{pkg}"
      end

    cvss_severity =
      get_in(vuln, ["database_specific", "severity"]) ||
        CveLookup.extract_cvss_severity(vuln)

    severity = CveLookup.map_severity(cvss_severity)
    fixed_version = extract_fixed_version(vuln)
    references = extract_references(vuln, cve_id, id)

    %{
      project_repository_id: repo_id,
      ecosystem: eco,
      package_name: pkg,
      package_version: ver,
      cve_id: cve_id,
      osv_id: id,
      severity: severity,
      summary: summary,
      details: vuln["details"],
      fixed_version: fixed_version,
      manifest_file: manifest_file,
      references: references,
      inserted_at: now,
      updated_at: now
    }
  end

  defp extract_fixed_version(vuln) do
    fixed_versions =
      for aff <- List.wrap(vuln["affected"]),
          range <- List.wrap(aff["ranges"]),
          event <- List.wrap(range["events"]),
          fixed = event["fixed"],
          is_binary(fixed) do
        fixed
      end

    case fixed_versions do
      [v | _] -> v
      _ -> nil
    end
  end

  defp extract_references(vuln, cve_id, id) do
    raw_refs =
      vuln
      |> Map.get("references", [])
      |> Enum.map(fn
        %{"url" => url} -> url
        url when is_binary(url) -> url
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    direct_refs =
      [
        if(String.starts_with?(cve_id, "CVE-"),
          do: "https://nvd.nist.gov/vuln/detail/#{cve_id}"
        ),
        "https://osv.dev/vulnerability/#{id}"
      ]
      |> Enum.reject(&is_nil/1)

    Enum.uniq(direct_refs ++ raw_refs) |> Enum.take(10)
  end

  defp clear_existing_vulnerabilities(repo_id) do
    ProjectRepositoryVulnerability
    |> where([v], v.project_repository_id == ^repo_id)
    |> Repo.delete_all()
  end

  defp set_scan_status(repo_id, status) do
    ProjectRepository
    |> where([r], r.id == ^repo_id)
    |> Repo.update_all(set: [scan_status: status])
  end

  defp update_repo_scan_results(repo_id, attrs) do
    ProjectRepository
    |> where([r], r.id == ^repo_id)
    |> Repo.update_all(set: Map.to_list(attrs))

    Repo.get!(ProjectRepository, repo_id)
  end

  defp mark_scan_error(repo, error_msg) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ProjectRepository
    |> where([r], r.id == ^repo.id)
    |> Repo.update_all(set: [scan_status: "error", last_scanned_at: now])

    Logger.warning("Repo scan error for #{repo.url}: #{error_msg}")
  end

  # ─── Domain Security Scan Integration ────────────────────────────────────────

  defp maybe_record_domain_sca_scan(%ProjectRepository{domain_id: domain_id} = repo, vulns)
       when is_integer(domain_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    total = length(vulns)

    summary =
      if total == 0 do
        "Clean — 0 vulnerabilities discovered in repository #{repo.url}"
      else
        "#{total} dependency #{if total == 1, do: "vulnerability", else: "vulnerabilities"} detected in #{repo.url}"
      end

    # Create completed SecurityScan for domain
    {:ok, scan} =
      SecurityScans.create_scan(%{
        domain_id: domain_id,
        tool: "repo_sca",
        status: "completed",
        started_at: now,
        completed_at: now,
        progress: 100,
        target: repo.url,
        summary: summary
      })

    if vulns != [] do
      findings =
        Enum.map(vulns, fn v ->
          %{
            severity: v.severity,
            title:
              "#{v.cve_id} — #{v.package_name} v#{v.package_version} (#{v.ecosystem}): #{v.summary}",
            target: repo.url,
            detail: %{
              "source" => "repo_sca",
              "cve" => v.cve_id,
              "osv_id" => v.osv_id,
              "tech" => v.package_name,
              "version" => v.package_version,
              "ecosystem" => v.ecosystem,
              "summary" => v.summary,
              "fixed_version" => v.fixed_version,
              "manifest_file" => v.manifest_file,
              "references" => v.references,
              "repository_id" => repo.id,
              "repository_url" => repo.url
            }
          }
        end)

      SecurityScans.create_findings_batch(scan.id, findings)
    end

    # Prune old scans to maintain database hygiene
    SecurityScans.prune_old_scans(domain_id)
  end

  defp maybe_record_domain_sca_scan(_repo, _vulns), do: :ok
end
