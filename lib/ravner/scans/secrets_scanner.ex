defmodule Ravner.Scans.SecretsScanner do
  @moduledoc """
  Functional in-process secrets and credential leak detection engine.

  Employs pattern-based signatures and Shannon entropy heuristics to detect
  exposed credentials (AWS keys, GitHub/GitLab tokens, Slack webhooks/tokens,
  private keys, database connection URIs, and high-entropy API secrets)
  during repository scans without external binary overhead.
  """

  import Ecto.Query
  require Logger

  alias Ravner.Integrations.VCS
  alias Ravner.Inventory.ProjectRepository
  alias Ravner.Repo
  alias Ravner.Scans.ProjectRepositorySecret
  alias Ravner.SecurityScans

  @candidate_config_files [
    ".env",
    ".env.local",
    ".env.production",
    ".env.staging",
    ".env.test",
    "config/runtime.exs",
    "config/prod.exs",
    "docker-compose.yml",
    "docker-compose.yaml",
    "Dockerfile",
    "application.yml",
    "application.properties",
    "settings.py",
    "config.json",
    ".npmrc",
    ".pypirc"
  ]

  @rules [
    %{
      id: "aws_access_key",
      name: "AWS Access Key ID",
      regex: ~r/\b(AKIA[0-9A-Z]{16})\b/,
      severity: "critical"
    },
    %{
      id: "github_pat",
      name: "GitHub Personal Access Token",
      regex: ~r/\b(ghp_[0-9a-zA-Z]{36})\b/,
      severity: "critical"
    },
    %{
      id: "github_fine_grained_pat",
      name: "GitHub Fine-Grained Personal Access Token",
      regex: ~r/\b(github_pat_[0-9a-zA-Z_]{20,})\b/,
      severity: "critical"
    },
    %{
      id: "gitlab_pat",
      name: "GitLab Personal Access Token",
      regex: ~r/\b(glpat-[0-9a-zA-Z\-_]{20,})\b/,
      severity: "critical"
    },
    %{
      id: "slack_token",
      name: "Slack Token",
      regex: ~r/\b(xox[baprs]-[0-9a-zA-Z\-]{10,80})\b/,
      severity: "high"
    },
    %{
      id: "slack_webhook",
      name: "Slack Incoming Webhook URL",
      regex:
        ~r/\b(https:\/\/hooks\.slack\.com\/services\/T[0-9A-Z]{8,12}\/B[0-9A-Z]{8,12}\/[0-9a-zA-Z]{24})\b/,
      severity: "high"
    },
    %{
      id: "private_key",
      name: "Private Key",
      regex: ~r/-----BEGIN ((?:RSA|DSA|EC|OPENSSH|PGP) )?PRIVATE KEY-----/,
      severity: "critical"
    },
    %{
      id: "db_connection_uri",
      name: "Database Connection URI with Credentials",
      regex: ~r/\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?):\/\/[^:\s\/]+:[^@\s\/]+@[^\s\/]+/,
      severity: "critical"
    }
  ]

  @entropy_assignment_regex ~r/(?:api_?key|secret_?key|secret(?:_key_base)?|auth_?token|access_?token|client_?secret|password|passwd)\s*[:=]\s*["']?([^\s"';]{20,})["']?/i
  @min_entropy_threshold 4.5
  @min_entropy_length 20

  # ─── Public Inspection & Utility APIs ────────────────────────────────────────

  @doc """
  Returns the list of candidate configuration and environment filenames checked
  during repository secrets scans.
  """
  @spec candidate_config_files() :: [String.t()]
  def candidate_config_files, do: @candidate_config_files

  @doc """
  Calculates the mathematical Shannon entropy of a string in bits per character.
  """
  @spec shannon_entropy(String.t()) :: float()
  def shannon_entropy(""), do: 0.0

  def shannon_entropy(str) when is_binary(str) do
    len = byte_size(str)

    frequencies =
      str
      |> :binary.bin_to_list()
      |> Enum.frequencies()

    Enum.reduce(frequencies, 0.0, fn {_char, count}, acc ->
      p = count / len
      acc - p * :math.log2(p)
    end)
  end

  @doc """
  Masks a raw credential string so it can be safely stored and displayed in UIs.
  """
  @spec mask_secret(String.t()) :: String.t()
  def mask_secret(secret) when is_binary(secret) do
    trimmed = String.trim(secret)
    len = String.length(trimmed)

    cond do
      len <= 8 ->
        first = String.slice(trimmed, 0, 1)
        last = String.slice(trimmed, -1, 1)
        "#{first}******#{last}"

      len <= 16 ->
        first = String.slice(trimmed, 0, 3)
        last = String.slice(trimmed, -3, 3)
        "#{first}********#{last}"

      true ->
        first = String.slice(trimmed, 0, 4)
        last = String.slice(trimmed, -4, 4)
        "#{first}************#{last}"
    end
  end

  @doc """
  Generates a SHA-256 fingerprint for a detected secret within a file path.
  """
  @spec fingerprint(String.t(), String.t()) :: String.t()
  def fingerprint(raw_secret, file_path) when is_binary(raw_secret) and is_binary(file_path) do
    :crypto.hash(:sha256, "#{String.trim(raw_secret)}:#{String.trim(file_path)}")
    |> Base.encode16(case: :lower)
  end

  @doc """
  Determines whether a file path should be excluded from secrets scanning.
  """
  @spec ignored_path?(String.t()) :: boolean()
  def ignored_path?(path) when is_binary(path) do
    clean_path = String.trim(path)
    basename = Path.basename(clean_path)

    cond do
      # Sample, example, template files
      String.ends_with?(basename, [".sample", ".example", ".template"]) ->
        true

      # Fixtures and test directories
      String.contains?(clean_path, ["fixtures/", "test/fixtures", "spec/fixtures"]) ->
        true

      # Documentation and text files
      String.ends_with?(basename, [".md", ".txt", ".rst", ".adoc"]) or
          String.starts_with?(basename, ["LICENSE", "CHANGELOG", "README"]) ->
        true

      # Dependency lockfiles
      basename in [
        "mix.lock",
        "package-lock.json",
        "yarn.lock",
        "pnpm-lock.yaml",
        "Cargo.lock",
        "composer.lock",
        "poetry.lock",
        "Pipfile.lock",
        "Gemfile.lock"
      ] ->
        true

      # Build artifacts and vendor directories
      String.contains?(clean_path, [
        "node_modules/",
        "_build/",
        "deps/",
        ".git/",
        ".elixir_ls/",
        "cover/"
      ]) ->
        true

      true ->
        false
    end
  end

  @doc """
  Scans file content line by line and returns a list of detected secret finding maps.

  ## Options
  - `:force` (boolean) - if true, scans content even if the path would be ignored.
  """
  @spec scan_content(String.t(), String.t(), keyword()) :: [map()]
  def scan_content(content, file_path \\ "file.txt", opts \\ [])

  def scan_content(content, file_path, opts) when is_binary(content) and is_binary(file_path) do
    if ignored_path?(file_path) and not Keyword.get(opts, :force, false) do
      []
    else
      content
      |> String.split(["\r\n", "\n", "\r"])
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_number} ->
        scan_line(line, line_number, file_path)
      end)
      |> Enum.uniq_by(fn finding -> finding.fingerprint_sha256 end)
    end
  end

  # ─── Repository Scan Pipeline ────────────────────────────────────────────────

  @doc """
  Scans candidate configuration and environment files in a repository for secrets.
  Returns `{:ok, %{repository: repo, secrets: [secret]}}` or `{:error, reason}`.
  """
  @spec scan_repository(ProjectRepository.t() | integer(), keyword()) ::
          {:ok, %{repository: ProjectRepository.t(), secrets: [ProjectRepositorySecret.t()]}}
          | {:error, String.t()}
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
        {:error, "Unable to determine repository slug from URL"}

      true ->
        case VCS.resolve_credentials(provider) do
          nil ->
            # Support mock files passed via opts for test environments
            if Keyword.has_key?(opts, :files) do
              scan_repository_files_with_map(repo, Keyword.get(opts, :files, %{}), opts)
            else
              {:error, "No active integration credentials configured for #{provider}"}
            end

          creds ->
            scan_repository_files(repo, provider, repo_slug, branch, creds, opts)
        end
    end
  end

  @doc """
  Fetches and scans candidate configuration files from a VCS provider.
  """
  @spec scan_repository_files(
          ProjectRepository.t(),
          String.t() | atom(),
          String.t(),
          String.t(),
          term(),
          keyword()
        ) :: {:ok, %{repository: ProjectRepository.t(), secrets: [ProjectRepositorySecret.t()]}}
  def scan_repository_files(repo, provider, repo_slug, branch, creds, opts \\ []) do
    scan_started_at = System.monotonic_time(:millisecond)

    files_to_check =
      Keyword.get(opts, :candidate_files, @candidate_config_files)

    # Fetch file contents from VCS
    files_map =
      files_to_check
      |> Enum.reduce(%{}, fn filename, acc ->
        case VCS.fetch_file(provider, repo_slug, filename, branch, creds) do
          {:ok, content} when is_binary(content) and content != "" ->
            Map.put(acc, filename, content)

          _ ->
            acc
        end
      end)

    finish_scan_with_files(repo, files_map, scan_started_at, provider, repo_slug, opts)
  end

  defp scan_repository_files_with_map(repo, files_map, opts) do
    scan_started_at = System.monotonic_time(:millisecond)
    provider = repo.provider || "bitbucket"
    repo_slug = repo.external_id || repo.url

    finish_scan_with_files(repo, files_map, scan_started_at, provider, repo_slug, opts)
  end

  defp finish_scan_with_files(repo, files_map, scan_started_at, provider, repo_slug, opts) do
    commit_sha = Keyword.get(opts, :commit_sha, repo.last_commit_hash)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Scan all fetched files
    findings =
      files_map
      |> Enum.flat_map(fn {filename, content} ->
        scan_content(content, filename, opts)
      end)
      |> Enum.uniq_by(& &1.fingerprint_sha256)

    # Prepare database records
    secret_attrs =
      Enum.map(findings, fn f ->
        %{
          project_repository_id: repo.id,
          project_id: repo.project_id,
          file_path: f.file_path,
          line_number: f.line_number,
          rule_id: f.rule_id,
          rule_name: f.rule_name,
          masked_value: f.masked_value,
          fingerprint_sha256: f.fingerprint_sha256,
          severity: f.severity,
          status: "active",
          commit_sha: commit_sha,
          inserted_at: now,
          updated_at: now
        }
      end)

    # Persist detected secrets (upsert to preserve existing resolved/false_positive statuses)
    if secret_attrs != [] do
      Repo.insert_all(
        ProjectRepositorySecret,
        secret_attrs,
        on_conflict: {:replace, [:commit_sha, :line_number, :updated_at]},
        conflict_target: [:project_repository_id, :fingerprint_sha256]
      )
    end

    # Fetch currently active secrets count
    active_count = count_active_secrets(repo.id)
    critical_count = count_active_critical_secrets(repo.id)
    high_count = count_active_high_secrets(repo.id)

    # Update ProjectRepository secrets_count
    ProjectRepository
    |> where([r], r.id == ^repo.id)
    |> Repo.update_all(set: [secrets_count: active_count])

    updated_repo = Repo.get!(ProjectRepository, repo.id)
    persisted_secrets = list_repository_secrets(repo.id)

    # Emit domain security scan if repo is attached to a domain
    maybe_record_domain_secrets_scan(updated_repo, persisted_secrets)

    # Recalculate domain risk score if repo is attached to a domain
    if updated_repo.domain_id do
      Ravner.Governance.RiskScore.recalculate_for_domain(updated_repo.domain_id)
    end

    # Emit synthetic telemetry
    duration_ms = System.monotonic_time(:millisecond) - scan_started_at

    Ravner.Telemetry.Synthetic.emit_secrets_scan(
      %{
        duration_ms: duration_ms,
        secrets_count: active_count,
        critical_count: critical_count,
        high_count: high_count
      },
      %{
        "vcs.provider" => to_string(provider),
        "vcs.repository.name" => repo_slug,
        "vcs.repository.url" => repo.url,
        "ravner.project_id" => repo.project_id,
        "ravner.domain_id" => repo.domain_id
      }
    )

    # Dispatch security alerts if active leaked secrets exist
    if active_count > 0 do
      Ravner.Notifications.dispatch_secret_leaks(updated_repo, persisted_secrets)
    end

    {:ok, %{repository: updated_repo, secrets: persisted_secrets}}
  end

  # ─── Query & Governance Operations ───────────────────────────────────────────

  @doc """
  Lists all secrets discovered in a repository, ordered by severity and insertion time.
  """
  @spec list_repository_secrets(integer(), keyword()) :: [ProjectRepositorySecret.t()]
  def list_repository_secrets(repo_id, opts \\ []) do
    status = Keyword.get(opts, :status)

    query =
      from(s in ProjectRepositorySecret,
        where: s.project_repository_id == ^repo_id,
        order_by: [
          fragment(
            "CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END",
            s.severity
          ),
          desc: s.inserted_at
        ]
      )

    query =
      if status do
        where(query, [s], s.status == ^to_string(status))
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Lists all secrets discovered across all repositories within a project.
  """
  @spec list_project_secrets(integer() | String.t(), keyword()) :: [ProjectRepositorySecret.t()]
  def list_project_secrets(project_id, opts \\ []) do
    status = Keyword.get(opts, :status)

    query =
      from(s in ProjectRepositorySecret,
        where: s.project_id == ^project_id,
        preload: [:project_repository],
        order_by: [
          fragment(
            "CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END",
            s.severity
          ),
          desc: s.inserted_at
        ]
      )

    query =
      if status do
        where(query, [s], s.status == ^to_string(status))
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Updates the lifecycle status of a secret finding (`"active"`, `"resolved"`, `"false_positive"`).
  """
  @spec mark_secret_status(integer(), String.t()) ::
          {:ok, ProjectRepositorySecret.t()} | {:error, term()}
  def mark_secret_status(secret_id, new_status)
      when new_status in ~w(active resolved false_positive) do
    case Repo.get(ProjectRepositorySecret, secret_id) do
      nil ->
        {:error, "Secret finding #{secret_id} not found"}

      secret ->
        secret
        |> ProjectRepositorySecret.changeset(%{status: new_status})
        |> Repo.update()
        |> case do
          {:ok, updated_secret} ->
            # Recalculate repository active secrets count
            active = count_active_secrets(secret.project_repository_id)

            ProjectRepository
            |> where([r], r.id == ^secret.project_repository_id)
            |> Repo.update_all(set: [secrets_count: active])

            repo = Repo.get(ProjectRepository, secret.project_repository_id)

            if repo && repo.domain_id do
              Ravner.Governance.RiskScore.recalculate_for_domain(repo.domain_id)
            end

            {:ok, updated_secret}

          error ->
            error
        end
    end
  end

  def mark_secret_status(_id, invalid_status) do
    {:error, "Invalid status: #{inspect(invalid_status)}"}
  end

  # ─── Internal Scan Helpers ───────────────────────────────────────────────────

  defp scan_line(line, line_number, file_path) do
    pattern_matches =
      Enum.flat_map(@rules, fn rule ->
        case Regex.run(rule.regex, line) do
          [full_match | _] ->
            [build_finding(rule.id, rule.name, full_match, rule.severity, file_path, line_number)]

          _ ->
            []
        end
      end)

    entropy_matches =
      case Regex.run(@entropy_assignment_regex, line) do
        [_full, value] ->
          clean_val = String.trim(value)

          if plausible_secret_candidate?(clean_val) and
               shannon_entropy(clean_val) >= @min_entropy_threshold do
            [
              build_finding(
                "high_entropy_secret",
                "High-Entropy Secret / Token",
                clean_val,
                "high",
                file_path,
                line_number
              )
            ]
          else
            []
          end

        _ ->
          []
      end

    pattern_matches ++ entropy_matches
  end

  defp build_finding(rule_id, rule_name, raw_value, severity, file_path, line_number) do
    %{
      rule_id: rule_id,
      rule_name: rule_name,
      file_path: file_path,
      line_number: line_number,
      masked_value: mask_secret(raw_value),
      fingerprint_sha256: fingerprint(raw_value, file_path),
      severity: severity
    }
  end

  defp plausible_secret_candidate?(str) do
    len = String.length(str)

    cond do
      len < @min_entropy_length ->
        false

      # Exclude placeholder strings
      String.starts_with?(str, [
        "YOUR_",
        "EXAMPLE",
        "SAMPLE",
        "CHANGE_ME",
        "PLACEHOLDER",
        "dummy",
        "mock"
      ]) ->
        false

      # Exclude all caps with underscores (likely an env var name)
      Regex.match?(~r/^[A-Z0-9_]+$/, str) and not String.starts_with?(str, "AKIA") ->
        false

      # Exclude repetitive characters (e.g. "aaaaaaaaaaaaaaaaaaaa")
      length(Enum.uniq(String.to_charlist(str))) < 6 ->
        false

      true ->
        true
    end
  end

  defp count_active_secrets(repo_id) do
    ProjectRepositorySecret
    |> where([s], s.project_repository_id == ^repo_id and s.status == "active")
    |> Repo.aggregate(:count, :id)
  end

  defp count_active_critical_secrets(repo_id) do
    ProjectRepositorySecret
    |> where(
      [s],
      s.project_repository_id == ^repo_id and s.status == "active" and s.severity == "critical"
    )
    |> Repo.aggregate(:count, :id)
  end

  defp count_active_high_secrets(repo_id) do
    ProjectRepositorySecret
    |> where(
      [s],
      s.project_repository_id == ^repo_id and s.status == "active" and s.severity == "high"
    )
    |> Repo.aggregate(:count, :id)
  end

  defp maybe_record_domain_secrets_scan(%ProjectRepository{domain_id: domain_id} = repo, secrets)
       when is_integer(domain_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    active_secrets = Enum.filter(secrets, &(&1.status == "active"))
    total = length(active_secrets)

    summary =
      if total == 0 do
        "Clean — 0 exposed credentials detected in repository #{repo.url}"
      else
        "#{total} credential leak#{if total == 1, do: "", else: "s"} detected in #{repo.url}"
      end

    {:ok, scan} =
      SecurityScans.create_scan(%{
        domain_id: domain_id,
        tool: "repo_secrets",
        status: "completed",
        started_at: now,
        completed_at: now,
        progress: 100,
        target: repo.url,
        summary: summary
      })

    if active_secrets != [] do
      findings =
        Enum.map(active_secrets, fn s ->
          %{
            severity: s.severity,
            title: "#{s.rule_name} exposed in #{s.file_path}:#{s.line_number}",
            target: repo.url,
            detail: %{
              "source" => "repo_secrets",
              "rule_id" => s.rule_id,
              "rule_name" => s.rule_name,
              "file_path" => s.file_path,
              "line_number" => s.line_number,
              "masked_value" => s.masked_value,
              "repository_id" => repo.id,
              "repository_url" => repo.url
            }
          }
        end)

      SecurityScans.create_findings_batch(scan.id, findings)
    end

    SecurityScans.prune_old_scans(domain_id)
  end

  defp maybe_record_domain_secrets_scan(_repo, _secrets), do: :ok
end
