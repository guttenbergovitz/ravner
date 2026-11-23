defmodule Ravner.Governance.RiskScore do
  @moduledoc """
  Deterministic Cyber Risk & Executive Posture Scoring Engine.
  Evaluates multi-factor risk across known vulnerabilities, hardcoded secret leaks,
  TLS/SSL certificate hygiene, HTTP security headers, and uptime availability.

  Calculates a normalized 0–100 health index and letter grade (A+ through F)
  with actionable deduction drivers for CISOs and Project Managers.
  """

  import Ecto.Query

  alias Ravner.Repo
  alias Ravner.Domains.{Domain, DomainMetadata}
  alias Ravner.Inventory.ProjectRepository
  alias Ravner.Scans.ProjectRepositorySecret

  @type risk_result :: %{
          overall_score: integer() | nil,
          grade: String.t(),
          deductions: %{
            vulnerabilities: integer(),
            secrets: integer(),
            ssl: integer(),
            headers: integer(),
            uptime: integer(),
            ports: integer()
          },
          drivers: [String.t()]
        }

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Calculates risk score and breakdown from raw metrics and findings.
  Accepts a map or keyword list with:
  * `:critical_vulns` (integer, default 0)
  * `:high_vulns` (integer, default 0)
  * `:medium_vulns` (integer, default 0)
  * `:active_secrets` (integer, default 0)
  * `:ssl_days_remaining` (integer or nil)
  * `:ssl_expired?` (boolean or inferred)
  * `:security_headers` (map of header strings)
  * `:uptime_ratio` (float between 0.0 and 1.0 or nil)
  * `:is_up` (boolean or nil)
  * `:open_ports` (list of integers)
  """
  @spec calculate(map() | keyword()) :: risk_result()
  def calculate(input) do
    data = normalize_input(input)

    # 1. Vulnerabilities deduction
    crit_count = Map.get(data, :critical_vulns, 0)
    high_count = Map.get(data, :high_vulns, 0)
    med_count = Map.get(data, :medium_vulns, 0)

    {vuln_pts, vuln_drivers} =
      compute_vuln_deductions(crit_count, high_count, med_count)

    # 2. Secret leaks deduction
    secrets_count = Map.get(data, :active_secrets, 0)
    {secret_pts, secret_drivers} = compute_secret_deductions(secrets_count)

    # 3. SSL/TLS deduction
    ssl_days = Map.get(data, :ssl_days_remaining)
    ssl_expired? = Map.get(data, :ssl_expired?, false)
    {ssl_pts, ssl_drivers} = compute_ssl_deductions(ssl_days, ssl_expired?)

    # 4. Security headers deduction
    headers = Map.get(data, :security_headers, %{})
    {header_pts, header_drivers} = compute_header_deductions(headers)

    # 5. Uptime & availability deduction
    uptime_ratio = Map.get(data, :uptime_ratio)
    is_up = Map.get(data, :is_up, true)
    {uptime_pts, uptime_drivers} = compute_uptime_deductions(uptime_ratio, is_up)

    # 6. Dangerous open ports deduction
    open_ports = Map.get(data, :open_ports, [])
    {port_pts, port_drivers} = compute_port_deductions(open_ports)

    total_deductions = vuln_pts + secret_pts + ssl_pts + header_pts + uptime_pts + port_pts
    raw_score = 100 - total_deductions
    score = Enum.max([0, Enum.min([100, raw_score])])
    grade = score_to_grade(score)

    drivers =
      vuln_drivers ++
        secret_drivers ++
        ssl_drivers ++
        header_drivers ++
        uptime_drivers ++
        port_drivers

    %{
      overall_score: score,
      grade: grade,
      deductions: %{
        vulnerabilities: vuln_pts,
        secrets: secret_pts,
        ssl: ssl_pts,
        headers: header_pts,
        uptime: uptime_pts,
        ports: port_pts
      },
      drivers: drivers
    }
  end

  @doc """
  Recalculates risk score for a domain by querying its metadata and attached repositories,
  and updates `domain_metadata` with the result.
  """
  @spec recalculate_for_domain(integer() | Domain.t()) :: {:ok, risk_result()} | {:error, term()}
  def recalculate_for_domain(domain_or_id)

  def recalculate_for_domain(domain_id) when is_integer(domain_id) do
    case Repo.get(Domain, domain_id) do
      nil -> {:error, :domain_not_found}
      domain -> recalculate_for_domain(domain)
    end
  end

  def recalculate_for_domain(%Domain{} = domain) do
    # Skip scoring for placeholder and redirect domains
    if Domain.hide_scoring?(domain) do
      result = %{
        overall_score: nil,
        grade: "N/A",
        deductions: %{
          vulnerabilities: 0,
          secrets: 0,
          ssl: 0,
          headers: 0,
          uptime: 0,
          ports: 0
        },
        drivers: ["Risk scoring not applicable for #{domain.lifecycle_state} domains."]
      }

      Ravner.Domains.upsert_domain_metadata(domain.id, %{
        risk_score: nil,
        risk_grade: "N/A",
        risk_deductions: result.deductions,
        risk_drivers: result.drivers
      })

      {:ok, result}
    else
      recalculate_for_domain_internal(domain)
    end
  end

  defp recalculate_for_domain_internal(%Domain{} = domain) do
    meta =
      Repo.get_by(DomainMetadata, domain_id: domain.id) || %DomainMetadata{domain_id: domain.id}

    # Fetch attached repository stats
    repos =
      ProjectRepository
      |> where(domain_id: ^domain.id)
      |> Repo.all()

    repo_crit = Enum.sum(Enum.map(repos, &(&1.critical_vuln_count || 0)))
    repo_high = Enum.sum(Enum.map(repos, &(&1.high_vuln_count || 0)))
    repo_med = Enum.sum(Enum.map(repos, &(&1.medium_vuln_count || 0)))

    # Fetch active domain security scan findings (CVEs, sensitive exposures, breach intel)
    # Exclude findings already evaluated under ports, SSL, headers, or repo SCA to avoid double-counting.
    domain_findings = Ravner.SecurityScans.list_all_active_findings_for_domain(domain.id)

    domain_vuln_findings =
      Enum.reject(domain_findings, fn f ->
        detail = f.detail || %{}
        detail["source"] in ["tls_audit", "headers_audit", "port_probe", "repo_sca"]
      end)

    domain_crit = Enum.count(domain_vuln_findings, &(&1.severity == "critical"))
    domain_high = Enum.count(domain_vuln_findings, &(&1.severity == "high"))
    domain_med = Enum.count(domain_vuln_findings, &(&1.severity == "medium"))

    crit_vulns = repo_crit + domain_crit
    high_vulns = repo_high + domain_high
    med_vulns = repo_med + domain_med

    # Fetch active secret leaks across attached repos
    repo_ids = Enum.map(repos, & &1.id)

    active_secrets =
      if repo_ids != [] do
        ProjectRepositorySecret
        |> where([s], s.project_repository_id in ^repo_ids and s.status == "active")
        |> Repo.aggregate(:count)
      else
        0
      end

    if not has_readings?(meta, repos, domain_findings) do
      result = %{
        overall_score: nil,
        grade: "N/A",
        deductions: %{
          vulnerabilities: 0,
          secrets: 0,
          ssl: 0,
          headers: 0,
          uptime: 0,
          ports: 0
        },
        drivers: [
          "No scans or probes have been recorded yet — cyber risk scoring pending initial scan."
        ]
      }

      Ravner.Domains.upsert_domain_metadata(domain.id, %{
        risk_score: nil,
        risk_grade: "N/A",
        risk_deductions: result.deductions,
        risk_drivers: result.drivers
      })

      {:ok, result}
    else
      input = %{
        critical_vulns: crit_vulns,
        high_vulns: high_vulns,
        medium_vulns: med_vulns,
        active_secrets: active_secrets,
        ssl_days_remaining: meta.ssl_days_remaining,
        security_headers: meta.security_headers || %{},
        is_up: meta.is_up,
        open_ports: meta.open_ports || []
      }

      result = calculate(input)

      # Persist updated risk score into domain_metadata
      Ravner.Domains.upsert_domain_metadata(domain.id, %{
        risk_score: result.overall_score,
        risk_grade: result.grade,
        risk_deductions: result.deductions,
        risk_drivers: result.drivers
      })

      {:ok, result}
    end
  end

  @doc """
  Calculates aggregate cyber risk score across all domains and repositories
  belonging to a specific Project.
  """
  @spec calculate_for_project(integer()) :: risk_result()
  def calculate_for_project(project_id) when is_integer(project_id) do
    # Fetch all repositories belonging to project
    repos =
      ProjectRepository
      |> where(project_id: ^project_id)
      |> Repo.all()

    repo_crit = Enum.sum(Enum.map(repos, &(&1.critical_vuln_count || 0)))
    repo_high = Enum.sum(Enum.map(repos, &(&1.high_vuln_count || 0)))
    repo_med = Enum.sum(Enum.map(repos, &(&1.medium_vuln_count || 0)))

    repo_ids = Enum.map(repos, & &1.id)

    active_secrets =
      if repo_ids != [] do
        ProjectRepositorySecret
        |> where([s], s.project_repository_id in ^repo_ids and s.status == "active")
        |> Repo.aggregate(:count)
      else
        0
      end

    # Fetch all domains belonging to project
    domains =
      Domain
      |> where(project_id: ^project_id)
      |> Repo.all()

    domain_ids = Enum.map(domains, & &1.id)

    # Fetch domain-level security findings across all domains in project
    domain_vuln_findings =
      Enum.flat_map(domain_ids, fn d_id ->
        Ravner.SecurityScans.list_all_active_findings_for_domain(d_id)
        |> Enum.reject(fn f ->
          detail = f.detail || %{}
          detail["source"] in ["tls_audit", "headers_audit", "port_probe", "repo_sca"]
        end)
      end)

    domain_crit = Enum.count(domain_vuln_findings, &(&1.severity == "critical"))
    domain_high = Enum.count(domain_vuln_findings, &(&1.severity == "high"))
    domain_med = Enum.count(domain_vuln_findings, &(&1.severity == "medium"))

    crit_vulns = repo_crit + domain_crit
    high_vulns = repo_high + domain_high
    med_vulns = repo_med + domain_med

    metas =
      if domain_ids != [] do
        DomainMetadata
        |> where([m], m.domain_id in ^domain_ids)
        |> Repo.all()
      else
        []
      end

    any_readings? =
      Enum.any?(metas, &has_readings?(&1)) or
        Enum.any?(repos, fn r ->
          not is_nil(r.last_scanned_at) or
            (r.critical_vuln_count || 0) > 0 or
            (r.high_vuln_count || 0) > 0 or
            (r.medium_vuln_count || 0) > 0
        end) or
        domain_vuln_findings != []

    if not any_readings? do
      %{
        overall_score: nil,
        grade: "N/A",
        deductions: %{
          vulnerabilities: 0,
          secrets: 0,
          ssl: 0,
          headers: 0,
          uptime: 0,
          ports: 0
        },
        drivers: [
          "No scans or probes have been recorded yet — project posture pending initial scan."
        ]
      }
    else
      min_ssl_days =
        metas
        |> Enum.map(& &1.ssl_days_remaining)
        |> Enum.reject(&is_nil/1)
        |> Enum.min(fn -> nil end)

      any_down? = Enum.any?(metas, &(&1.is_up == false))

      combined_headers =
        if metas == [] do
          %{
            "strict-transport-security" => "present",
            "content-security-policy" => "present",
            "x-frame-options" => "present"
          }
        else
          Enum.reduce(metas, %{}, fn m, acc ->
            Map.merge(acc, m.security_headers || %{})
          end)
        end

      combined_ports =
        metas
        |> Enum.flat_map(&(&1.open_ports || []))
        |> Enum.uniq()

      input = %{
        critical_vulns: crit_vulns,
        high_vulns: high_vulns,
        medium_vulns: med_vulns,
        active_secrets: active_secrets,
        ssl_days_remaining: min_ssl_days,
        security_headers: combined_headers,
        is_up: !any_down?,
        open_ports: combined_ports
      }

      calculate(input)
    end
  end

  @doc """
  Checks whether domain metadata, attached repositories, or security scan findings
  contain active readings/telemetry. Returns `false` when no scans or probes have run.
  """
  @spec has_readings?(DomainMetadata.t() | nil, [ProjectRepository.t()], [term()]) :: boolean()
  def has_readings?(meta, repos \\ [], findings \\ []) do
    has_meta_readings =
      case meta do
        nil ->
          false

        %DomainMetadata{} = m ->
          not is_nil(m.scanned_at) or
            not is_nil(m.http_scanned_at) or
            not is_nil(m.last_security_scan_at) or
            not is_nil(m.last_heartbeat_at) or
            not is_nil(m.ssl_days_remaining) or
            not is_nil(m.http_status) or
            not is_nil(m.dns_scanned_at) or
            (is_map(m.security_headers) and map_size(m.security_headers) > 0) or
            (is_list(m.open_ports) and m.open_ports != [])
      end

    has_repo_readings =
      Enum.any?(repos, fn r ->
        not is_nil(r.last_scanned_at) or
          (r.critical_vuln_count || 0) > 0 or
          (r.high_vuln_count || 0) > 0 or
          (r.medium_vuln_count || 0) > 0
      end)

    has_findings = findings != []

    has_meta_readings or has_repo_readings or has_findings
  end

  @doc """
  Converts a 0–100 integer score into an executive letter grade (A+ through F).
  Returns "N/A" when score is nil (pending initial scans).
  """
  @spec score_to_grade(integer() | nil) :: String.t()
  def score_to_grade(nil), do: "N/A"

  def score_to_grade(score) when is_integer(score) do
    cond do
      score >= 95 -> "A+"
      score >= 90 -> "A"
      score >= 80 -> "B"
      score >= 65 -> "C"
      score >= 50 -> "D"
      true -> "F"
    end
  end

  @doc """
  Returns Tailwind CSS styling classes for rendering grade badges in UI.
  """
  @spec badge_classes(String.t()) :: String.t()
  def badge_classes(grade) do
    case grade do
      g when g in ["A+", "A"] ->
        "bg-emerald-50 text-emerald-700 border-emerald-200 dark:bg-emerald-950/50 dark:text-emerald-300 dark:border-emerald-800"

      "B" ->
        "bg-blue-50 text-blue-700 border-blue-200 dark:bg-blue-950/50 dark:text-blue-300 dark:border-blue-800"

      "C" ->
        "bg-amber-50 text-amber-700 border-amber-200 dark:bg-amber-950/50 dark:text-amber-300 dark:border-amber-800"

      "D" ->
        "bg-orange-50 text-orange-700 border-orange-200 dark:bg-orange-950/50 dark:text-orange-300 dark:border-orange-800"

      "F" ->
        "bg-red-50 text-red-700 border-red-200 dark:bg-red-950/50 dark:text-red-300 dark:border-red-800"

      _ ->
        "bg-neutral-100 text-neutral-600 border-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:border-neutral-700"
    end
  end

  # ── Deduction Calculation Helpers ──────────────────────────────────────────

  defp compute_vuln_deductions(crit, high, med) do
    crit_pts = crit * 25
    high_pts = high * 10
    med_pts = med * 3

    total_pts = crit_pts + high_pts + med_pts

    drivers = []

    drivers =
      if crit > 0,
        do:
          drivers ++
            ["#{crit} Critical CVE / vulnerability finding(s) detected (-#{crit_pts} pts)"],
        else: drivers

    drivers =
      if high > 0,
        do:
          drivers ++
            ["#{high} High-severity CVE / vulnerability finding(s) detected (-#{high_pts} pts)"],
        else: drivers

    drivers =
      if med > 0,
        do:
          drivers ++
            ["#{med} Medium-severity CVE / vulnerability finding(s) detected (-#{med_pts} pts)"],
        else: drivers

    {total_pts, drivers}
  end

  defp compute_secret_deductions(count) when count > 0 do
    pts = count * 20
    drivers = ["#{count} Active hardcoded secret/credential leak(s) in repository (-#{pts} pts)"]
    {pts, drivers}
  end

  defp compute_secret_deductions(_), do: {0, []}

  defp compute_ssl_deductions(days, expired?) do
    cond do
      expired? or (is_integer(days) and days < 0) ->
        {30, ["SSL/TLS Certificate is EXPIRED (-30 pts)"]}

      is_integer(days) and days <= 14 ->
        {15, ["SSL/TLS Certificate expiring in #{days} days (-15 pts)"]}

      is_integer(days) and days <= 30 ->
        {5, ["SSL/TLS Certificate renewal recommended within #{days} days (-5 pts)"]}

      true ->
        {0, []}
    end
  end

  defp compute_header_deductions(headers) when is_map(headers) do
    normalized =
      Map.new(headers, fn {k, v} ->
        {to_string(k) |> String.downcase(), v}
      end)

    hsts? = Map.has_key?(normalized, "strict-transport-security")
    csp? = Map.has_key?(normalized, "content-security-policy")

    frame? =
      Map.has_key?(normalized, "x-frame-options") or
        String.contains?(Map.get(normalized, "content-security-policy", ""), "frame-ancestors")

    pts = 0
    drivers = []

    {pts, drivers} =
      if !hsts? do
        {pts + 5, drivers ++ ["Missing HTTP Strict Transport Security (HSTS) header (-5 pts)"]}
      else
        {pts, drivers}
      end

    {pts, drivers} =
      if !csp? do
        {pts + 5, drivers ++ ["Missing Content-Security-Policy (CSP) header (-5 pts)"]}
      else
        {pts, drivers}
      end

    {pts, drivers} =
      if !frame? do
        {pts + 5,
         drivers ++
           ["Missing clickjacking protection (X-Frame-Options or frame-ancestors) (-5 pts)"]}
      else
        {pts, drivers}
      end

    {pts, drivers}
  end

  defp compute_uptime_deductions(ratio, is_up) do
    pts = 0
    drivers = []

    {pts, drivers} =
      if is_up == false do
        {pts + 15, drivers ++ ["Target domain is currently DOWN / unreachable (-15 pts)"]}
      else
        {pts, drivers}
      end

    {pts, drivers} =
      cond do
        is_float(ratio) and ratio < 0.95 ->
          p = 10

          {pts + p,
           drivers ++
             [
               "30-day uptime availability (#{Float.round(ratio * 100, 2)}%) is below 95% SLA target (-#{p} pts)"
             ]}

        is_float(ratio) and ratio < 0.999 ->
          p = 5

          {pts + p,
           drivers ++
             [
               "30-day uptime availability (#{Float.round(ratio * 100, 2)}%) is below 99.9% target (-#{p} pts)"
             ]}

        true ->
          {pts, drivers}
      end

    {pts, drivers}
  end

  defp compute_port_deductions(open_ports) when is_list(open_ports) do
    risky_ports = [
      {21, "FTP (21)"},
      {22, "SSH (22)"},
      {23, "Telnet (23)"},
      {3306, "MySQL (3306)"},
      {5432, "PostgreSQL (5432)"},
      {6379, "Redis (6379)"},
      {27017, "MongoDB (27017)"}
    ]

    exposed =
      Enum.filter(risky_ports, fn {port, _desc} ->
        port in open_ports
      end)

    if exposed != [] do
      pts = Enum.min([15, length(exposed) * 5])
      port_names = Enum.map_join(exposed, ", ", fn {_p, desc} -> desc end)
      drivers = ["Exposed sensitive/administrative port(s): #{port_names} (-#{pts} pts)"]
      {pts, drivers}
    else
      {0, []}
    end
  end

  defp normalize_input(list) when is_list(list), do: Map.new(list)
  defp normalize_input(map) when is_map(map), do: map
  defp normalize_input(_), do: %{}
end
