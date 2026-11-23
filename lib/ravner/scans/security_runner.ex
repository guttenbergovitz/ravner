defmodule Ravner.Scans.SecurityRunner do
  @moduledoc """
  On-demand lean security scanner.

  A single `run_security_scan/2` entry point chains:

      HTTP probe via Req (tech, status, server, redirects)
        │
        ▼
      naabu (top-100 port discovery)
        │
        ▼
      nuclei (critical/high only, against the host's HTTP/HTTPS surface)

  Findings are persisted through `Ravner.SecurityScans` and the captured
  HTTP / port / tech data is upserted into `domain_metadata` so it composes
  with the rest of the domain page.
  """

  require Logger

  import Ecto.Query

  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Domains.TechEvidence
  alias Ravner.Repo
  alias Ravner.SecurityScans
  alias Ravner.SecurityScans.SecurityScan
  alias Ravner.SystemCommand

  @naabu_timeout 120_000
  @nuclei_timeout 240_000

  # Global scan deadline (ms) - enforced across all phases
  # Light: 5 minutes (HTTP + CVE + TLS + ports)
  # Heavy: 10 minutes (HTTP + naabu + nuclei)
  @light_scan_deadline_ms 5 * 60 * 1000
  @heavy_scan_deadline_ms 10 * 60 * 1000

  # ─── Public API ───────────────────────────────────────────────────────────

  @doc """
  Runs a security scan for a domain, in `:light` or `:heavy` mode.

  - **Light** (default for scheduled scans): native HTTP probe + CVE lookup
    via OSV.dev. No external binaries, seconds per domain.
  - **Heavy**: full pipeline — HTTP probe → naabu → nuclei/lonkero.
    Expensive OS processes; intended for on-demand use.

  Mode defaults to `ScanConfig.security_scan_mode` when not given.

  Persists findings, upserts derived metadata into `domain_metadata`, and
  reports `{:scan_progress, ...}` / `{:scan_done, :security_scan, ...}` to
  the calling LiveView pid.
  """
  @spec run_security_scan(integer(), pid() | nil, integer() | nil, :light | :heavy | nil) ::
          {:ok, SecurityScan.t()} | {:error, String.t()}
  def run_security_scan(domain_id, liveview_pid, user_id \\ nil, mode \\ nil) do
    mode = mode || scan_mode_from_config()
    tool = if mode == :heavy, do: "security_scan", else: "light_scan"

    with :ok <- authorize_scan(domain_id, user_id),
         {:ok, domain} <- fetch_domain_for_scan(domain_id),
         {:ok, scan} <- create_security_scan(domain_id, tool, domain.name) do
      send_progress(scan.id, 5, liveview_pid)

      Task.Supervisor.start_child(Ravner.ScanTaskSupervisor, fn ->
        if user_id, do: Ravner.ActivityLog.set_user(user_id)
        do_security_scan(scan, domain.name, liveview_pid, mode)
      end)

      {:ok, scan}
    end
  end

  @doc """
  Runs a security scan synchronously in the current process without spawning a task.
  Useful for bulk operations (e.g. `Task.async_stream`) and Oban background jobs.
  """
  @spec run_security_scan_sync(integer(), integer() | nil, :light | :heavy | nil) ::
          {:ok, SecurityScan.t()} | {:error, String.t()}
  def run_security_scan_sync(domain_id, user_id \\ nil, mode \\ nil) do
    if user_id, do: Ravner.ActivityLog.set_user(user_id)
    mode = mode || scan_mode_from_config()
    tool = if mode == :heavy, do: "security_scan", else: "light_scan"

    with :ok <- authorize_scan(domain_id, user_id),
         {:ok, domain} <- fetch_domain_for_scan(domain_id),
         {:ok, scan} <- create_security_scan(domain_id, tool, domain.name) do
      do_security_scan(scan, domain.name, nil, mode)
    end
  end

  @doc """
  Runs an on-demand breach and dark web infostealer intelligence scan.
  """
  @spec run_breach_scan(integer(), pid() | nil, integer() | nil) ::
          {:ok, SecurityScan.t()} | {:error, String.t()}
  def run_breach_scan(domain_id, liveview_pid, user_id \\ nil) do
    tool = "breach_lookup"

    with :ok <- authorize_scan(domain_id, user_id),
         {:ok, domain} <- fetch_domain_for_scan(domain_id),
         {:ok, scan} <- create_security_scan(domain_id, tool, domain.name) do
      send_progress(scan.id, 10, liveview_pid)

      Task.Supervisor.start_child(Ravner.ScanTaskSupervisor, fn ->
        if user_id, do: Ravner.ActivityLog.set_user(user_id)
        do_breach_scan(scan, domain.name, liveview_pid)
      end)

      {:ok, scan}
    end
  end

  defp authorize_scan(_domain_id, nil), do: :ok

  defp authorize_scan(domain_id, user_id) do
    user = Ravner.Accounts.get_user!(user_id)

    if Ravner.Accounts.ScopeResolver.can_scan_domain?(user, domain_id) do
      :ok
    else
      {:error, "Unauthorized to scan this domain"}
    end
  rescue
    _ -> {:error, "User not found or unauthorized"}
  end

  defp scan_mode_from_config do
    case Ravner.ScanConfig.get().security_scan_mode do
      "heavy" -> :heavy
      _ -> :light
    end
  end

  # ─── Domain / scan helpers ────────────────────────────────────────────────

  defp fetch_domain_for_scan(domain_id) do
    case Repo.get(Domain, domain_id) do
      nil -> {:error, "Domain not found"}
      domain -> {:ok, domain}
    end
  end

  defp create_security_scan(domain_id, tool, target) do
    case SecurityScans.create_scan(%{
           domain_id: domain_id,
           tool: tool,
           status: "running",
           target: target,
           started_at: DateTime.utc_now()
         }) do
      {:ok, scan} ->
        {:ok, scan}

      {:error, changeset} ->
        Logger.error("Failed to create security scan: #{inspect(changeset.errors)}")
        {:error, "Failed to create security scan"}
    end
  end

  defp send_progress(scan_id, progress, liveview_pid) do
    # Persist progress to DB so UI re-fetches correct state
    case Repo.get(SecurityScan, scan_id) do
      nil -> :ok
      scan -> SecurityScans.update_scan(scan, %{progress: progress})
    end

    if is_pid(liveview_pid), do: send(liveview_pid, {:scan_progress, scan_id, progress})
  end

  # ─── Lean security scan runner ────────────────────────────────────────────

  defp do_security_scan(scan, domain_name, liveview_pid, mode) do
    send_progress(scan.id, 5, liveview_pid)

    # Calculate global deadline for this scan
    deadline_ms = if mode == :heavy, do: @heavy_scan_deadline_ms, else: @light_scan_deadline_ms
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    case mode do
      :light -> run_light_pipeline(scan, domain_name, liveview_pid, deadline)
      :heavy -> run_heavy_pipeline(scan, domain_name, liveview_pid, deadline)
    end
  rescue
    ErlangError ->
      fail_scan(scan, "scanner executable not found or failed to run", liveview_pid)

    e ->
      fail_scan(scan, "unexpected error during scan: #{inspect(e)}", liveview_pid)
  end

  # Returns :ok if deadline not exceeded, {:error, :deadline_exceeded} otherwise
  defp check_deadline(deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      :ok
    else
      {:error, :deadline_exceeded}
    end
  end

  defp do_breach_scan(scan, domain_name, liveview_pid) do
    send_progress(scan.id, 25, liveview_pid)

    Ravner.ActivityLog.emit(
      :step,
      "Security — checking dark web infostealer logs for #{domain_name}…"
    )

    send_progress(scan.id, 50, liveview_pid)

    case Ravner.Scans.BreachLookup.lookup(domain_name) do
      {:ok, stats, findings} ->
        send_progress(scan.id, 85, liveview_pid)

        summary =
          cond do
            stats.employees > 0 ->
              "#{stats.heat_label}: #{stats.employees} compromised employees, #{stats.users} users"

            stats.users > 0 ->
              "#{stats.heat_label}: #{stats.users} compromised customer accounts"

            true ->
              "Clean: no infostealer records detected in dark web logs"
          end

        if findings != [] do
          # Persist each finding, but keep existing status if already stored
          Enum.each(findings, fn f ->
            attrs = %{
              domain: domain_name,
              title: f.title,
              severity: f.severity,
              detail: f.detail,
              source: Map.get(f.detail, "source"),
              external_id: Map.get(f.detail, "external_id")
            }

            case Ravner.BreachFindingCtx.upsert_finding(attrs) do
              {:ok, _} ->
                :ok

              {:error, changeset} ->
                Logger.error("Failed to upsert breach finding: #{inspect(changeset.errors)}")
            end

            Ravner.ActivityLog.emit(:step, "  🚨 [#{f.severity}] #{f.title}")
          end)
        else
          Ravner.ActivityLog.emit(:step, "  ✓ #{summary}")
        end

        raw_output = Jason.encode!(stats)
        finalize_scan(scan, findings, raw_output, summary, liveview_pid)

      {:error, reason} ->
        Ravner.ActivityLog.emit(:error, "Dark web breach lookup failed: #{reason}")
        fail_scan(scan, reason, liveview_pid)
    end
  rescue
    e ->
      fail_scan(scan, "unexpected error during breach lookup: #{inspect(e)}", liveview_pid)
  end

  # Light: native HTTP probe + tech fingerprint + curated probes + CVE lookup + TLS/headers + port probe.
  defp run_light_pipeline(scan, domain_name, liveview_pid, deadline) do
    with :ok <- check_deadline(deadline),
         {probe_output, probe_metadata, target_url} <-
           light_phase_http_probe(scan, domain_name, liveview_pid),
         :ok <- check_deadline(deadline),
         :ok <- light_phase_fingerprint(scan, target_url, liveview_pid),
         :ok <- check_deadline(deadline),
         {:ok, curated_findings} <- light_phase_curated_probes(scan, target_url, liveview_pid),
         :ok <- check_deadline(deadline),
         {:ok, cve_findings} <- light_phase_cve_lookup(scan, domain_name, liveview_pid),
         :ok <- check_deadline(deadline),
         {:ok, tls_header_findings} <-
           light_phase_tls_headers(scan, domain_name, probe_metadata, target_url, liveview_pid),
         :ok <- check_deadline(deadline),
         {:ok, open_ports, port_findings} <-
           light_phase_port_probe(scan, domain_name, probe_metadata, liveview_pid) do
      all_findings =
        port_findings ++ cve_findings ++ curated_findings ++ tls_header_findings

      metadata_attrs =
        probe_metadata
        |> Map.put(:open_ports, open_ports)
        |> Map.put(:last_security_scan_at, DateTime.utc_now())

      persist_metadata(scan.domain_id, metadata_attrs)

      summary_parts =
        [
          if(cve_findings != [], do: "#{length(cve_findings)} CVEs", else: nil),
          if(curated_findings != [], do: "#{length(curated_findings)} exposures", else: nil),
          if(port_findings != [], do: "#{length(port_findings)} exposed services", else: nil),
          if(tls_header_findings != [],
            do: "#{length(tls_header_findings)} TLS/header issues",
            else: nil
          ),
          "#{length(open_ports)} ports"
        ]
        |> Enum.reject(&is_nil/1)

      summary =
        if summary_parts == [],
          do: "Clean: no vulnerabilities detected",
          else: Enum.join(summary_parts, ", ")

      finalize_scan(scan, all_findings, probe_output, summary, liveview_pid)
    else
      {:error, :deadline_exceeded} ->
        fail_scan(scan, "scan exceeded 5 minute deadline", liveview_pid)
    end
  end

  defp light_phase_http_probe(scan, domain_name, liveview_pid) do
    Ravner.ActivityLog.emit(:step, "Security (light) — HTTP probe #{domain_name}…")
    send_progress(scan.id, 15, liveview_pid)
    {probe_output, probe_metadata} = run_http_probe(scan)
    target_url = probe_metadata[:final_url] || "https://#{domain_name}"
    {probe_output, probe_metadata, target_url}
  end

  defp light_phase_fingerprint(scan, target_url, liveview_pid) do
    Ravner.ActivityLog.emit(:step, "Security (light) — Fingerprinting technologies…")
    send_progress(scan.id, 30, liveview_pid)
    maybe_sync_light_tech_evidence(scan.domain_id, target_url)
    :ok
  end

  defp light_phase_curated_probes(scan, target_url, liveview_pid) do
    Ravner.ActivityLog.emit(
      :step,
      "Security (light) — Testing curated exposure probes (.env, .git, panels)…"
    )

    send_progress(scan.id, 45, liveview_pid)
    {:ok, curated_findings} = Ravner.Scans.CuratedProbes.probe(target_url)

    Enum.each(curated_findings, fn f ->
      Ravner.ActivityLog.emit(:step, "  🚨 [#{f.severity}] #{f.title}")
    end)

    {:ok, curated_findings}
  end

  defp light_phase_cve_lookup(scan, domain_name, liveview_pid) do
    Ravner.ActivityLog.emit(:step, "Security (light) — CVE lookup via OSV.dev…")
    send_progress(scan.id, 65, liveview_pid)
    {:ok, cve_findings} = Ravner.Scans.CveLookup.lookup(scan.domain_id, domain_name)

    if cve_findings != [] do
      Enum.each(Enum.take(cve_findings, 5), fn f ->
        Ravner.ActivityLog.emit(:step, "  ⚠ [#{f.severity}] #{f.title}")
      end)

      if length(cve_findings) > 5 do
        Ravner.ActivityLog.emit(:step, "  … and #{length(cve_findings) - 5} more findings")
      end
    else
      Ravner.ActivityLog.emit(:step, "No known CVEs for detected technology versions")
    end

    {:ok, cve_findings}
  end

  defp light_phase_tls_headers(scan, domain_name, probe_metadata, target_url, liveview_pid) do
    Ravner.ActivityLog.emit(
      :step,
      "Security (light) — Auditing TLS protocols & security headers…"
    )

    send_progress(scan.id, 80, liveview_pid)

    {:ok, tls_header_findings} =
      Ravner.Scans.TlsHeaderAudit.audit(domain_name,
        headers: probe_metadata[:headers],
        final_url: target_url
      )

    Enum.each(tls_header_findings, fn f ->
      if f.severity in ["critical", "high"] do
        Ravner.ActivityLog.emit(:step, "  🚨 [#{f.severity}] #{f.title}")
      end
    end)

    {:ok, tls_header_findings}
  end

  defp light_phase_port_probe(scan, domain_name, probe_metadata, liveview_pid) do
    Ravner.ActivityLog.emit(:step, "Security (light) — Probing ports & sensitive services…")
    send_progress(scan.id, 90, liveview_pid)

    base_ports = extract_port_from_url(probe_metadata[:final_url])

    {:ok, open_ports, port_findings} =
      Ravner.Scans.PortProbe.probe(domain_name, base_ports: base_ports)

    Enum.each(port_findings, fn f ->
      Ravner.ActivityLog.emit(:step, "  🚨 [#{f.severity}] #{f.title}")
    end)

    {:ok, open_ports, port_findings}
  end

  defp maybe_sync_light_tech_evidence(domain_id, target_url) do
    case Ravner.Scans.TechFingerprint.fingerprint_url(target_url) do
      {:ok, new_evidence} when new_evidence != [] ->
        existing =
          TechEvidence
          |> where([e], e.domain_id == ^domain_id)
          |> Repo.all()
          |> Enum.map(fn e ->
            %{
              "name" => e.name,
              "version" => e.version,
              "confidence" => e.confidence,
              "source" => e.source
            }
          end)

        merged =
          (new_evidence ++ existing)
          |> Enum.uniq_by(fn e ->
            String.downcase(to_string(e[:name] || e["name"]))
          end)

        Domains.sync_tech_evidence(domain_id, merged)

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.debug("Tech fingerprinting during light scan failed: #{inspect(e)}")
      :ok
  end

  # Heavy: full pipeline with naabu port discovery + nuclei/lonkero.
  defp run_heavy_pipeline(scan, domain_name, liveview_pid, deadline) do
    config = Ravner.ScanConfig.get()
    active_scanner = config.security_scanner

    with :ok <- check_deadline(deadline),
         :ok <- check_binary("naabu"),
         :ok <- check_binary(active_scanner) do
      run_pipeline(scan, domain_name, liveview_pid, config, deadline)
    else
      {:error, :deadline_exceeded} ->
        fail_scan(scan, "scan exceeded 10 minute deadline", liveview_pid)

      {:error, reason} ->
        fail_scan(scan, reason, liveview_pid)
    end
  end

  defp run_pipeline(scan, domain_name, liveview_pid, config, deadline) do
    # Phase 1: native HTTP probe (status, server, tech, redirects)
    Ravner.ActivityLog.emit(:step, "Security — HTTP fingerprinting #{domain_name}…")
    send_progress(scan.id, 10, liveview_pid)
    {httpx_output, httpx_metadata} = run_http_probe(scan)

    server = httpx_metadata[:server_header]
    tech = httpx_metadata[:tech_stack] || []

    if server || tech != [] do
      tech_info = if tech != [], do: " [#{Enum.join(tech, ", ")}]", else: ""
      Ravner.ActivityLog.emit(:step, "Detected: #{server || "unknown server"}#{tech_info}")
    end

    # Check deadline before Phase 2
    case check_deadline(deadline) do
      {:error, :deadline_exceeded} ->
        fail_scan(scan, "scan exceeded 10 minute deadline", liveview_pid)

      :ok ->
        # Phase 2: naabu port discovery
        Ravner.ActivityLog.emit(:step, "Security — port scanning #{domain_name} (top 100)…")
        send_progress(scan.id, 35, liveview_pid)

        case run_naabu(domain_name) do
          {:ok, naabu_output, ports} ->
            naabu_findings = SecurityScans.parse_naabu_output(naabu_output)

            # Fallback: if naabu finds nothing (SYN blocked by firewall) but the
            # HTTP probe reached the site, include the observed port
            ports =
              if ports == [] do
                extract_port_from_url(httpx_metadata[:final_url])
              else
                ports
              end

            port_info = if ports != [], do: ": #{Enum.join(ports, ", ")}", else: ""
            Ravner.ActivityLog.emit(:step, "Found #{length(ports)} open ports#{port_info}")

            # Check deadline before Phase 3
            case check_deadline(deadline) do
              {:error, :deadline_exceeded} ->
                fail_scan(scan, "scan exceeded 10 minute deadline", liveview_pid)

              :ok ->
                # Phase 3: vulnerability scan
                active_scanner = config.security_scanner

                Ravner.ActivityLog.emit(
                  :step,
                  "Security — running #{active_scanner} vulnerability scan…"
                )

                send_progress(scan.id, 60, liveview_pid)

                scan_result =
                  if active_scanner == "lonkero" do
                    run_lonkero(domain_name)
                  else
                    run_nuclei(scan.domain_id, domain_name, config, httpx_metadata)
                  end

                case scan_result do
                  {:ok, scanner_findings} ->
                    send_progress(scan.id, 90, liveview_pid)

                    if scanner_findings != [] do
                      Enum.each(Enum.take(scanner_findings, 5), fn f ->
                        severity = f[:severity] || f["severity"] || "medium"
                        name = f[:title] || f["name"] || f["template_id"] || "unknown"
                        Ravner.ActivityLog.emit(:step, "  ⚠ [#{severity}] #{name}")
                      end)

                      if length(scanner_findings) > 5 do
                        Ravner.ActivityLog.emit(
                          :step,
                          "  … and #{length(scanner_findings) - 5} more findings"
                        )
                      end
                    else
                      Ravner.ActivityLog.emit(:step, "No vulnerabilities found — clean scan")
                    end

                    all_findings = naabu_findings ++ scanner_findings

                    summary =
                      "#{length(ports)} open ports, " <>
                        "#{length(scanner_findings)} findings"

                    metadata_attrs =
                      httpx_metadata
                      |> Map.put(:open_ports, ports)
                      |> Map.put(:last_security_scan_at, DateTime.utc_now())

                    persist_metadata(scan.domain_id, metadata_attrs)

                    finalize_scan(
                      scan,
                      all_findings,
                      naabu_output <> "\n---\n" <> httpx_output,
                      summary,
                      liveview_pid
                    )

                  {:error, reason} ->
                    Ravner.ActivityLog.emit(:error, "#{active_scanner} failed: #{reason}")
                    fail_scan(scan, "#{active_scanner}: #{reason}", liveview_pid)
                end
            end

          {:error, reason} ->
            Ravner.ActivityLog.emit(:error, "Port scan failed: #{reason}")
            fail_scan(scan, "naabu: #{reason}", liveview_pid)
        end
    end
  end

  # ─── Phase implementations ────────────────────────────────────────────────

  defp run_http_probe(scan) do
    case Ravner.Scans.Http.run_httpx_scan(scan.domain_id) do
      {:ok, %{error: _}} ->
        {"", %{}}

      {:ok, data} ->
        raw =
          data
          |> Map.take([:http_status, :final_url, :server_header, :tech_stack, :hosting_platform])
          |> Jason.encode!()

        metadata =
          %{
            tech_stack: data.tech_stack || [],
            http_status: data.http_status,
            final_url: data.final_url,
            server_header: data.server_header,
            headers: data.security_headers,
            hosting_platform: data.hosting_platform
          }
          |> drop_empty()

        {raw, metadata}

      {:error, _reason} ->
        {"", %{}}
    end
  end

  defp run_naabu(domain_name) do
    args = [
      "-host",
      domain_name,
      "-json",
      "-silent",
      "-stream",
      "-top-ports",
      "100",
      "-retries",
      "1"
    ]

    case SystemCommand.run_with_timeout("naabu", args, @naabu_timeout) do
      {output, 0} ->
        {:ok, output, extract_ports_from_naabu(output)}

      {:error, :timeout} ->
        {:error, "timed out after #{@naabu_timeout}ms"}

      {:error, reason} ->
        {:error, reason}

      {output, code} ->
        {:error, "exited with code #{code}: #{String.slice(output, 0, 200)}"}
    end
  end

  defp run_nuclei(domain_id, domain_name, config, httpx_metadata) do
    # 1. Gather technologies from the HTTP probe metadata
    probe_techs = Map.get(httpx_metadata, :tech_stack, [])
    server_header = Map.get(httpx_metadata, :server_header, "")

    # 2. Gather technologies from the DB (DomainMetadata + TechEvidence)
    db_metadata = Repo.get_by(Ravner.Domains.DomainMetadata, domain_id: domain_id)
    db_tech_stack = (db_metadata && db_metadata.tech_stack) || []
    db_server_header = (db_metadata && db_metadata.server_header) || ""

    db_tech_evidence =
      Repo.all(
        from(e in Ravner.Domains.TechEvidence,
          where: e.domain_id == ^domain_id,
          select: e.name
        )
      )

    # Combine all detected technology strings
    detected_tech_strings =
      (probe_techs ++
         db_tech_stack ++
         db_tech_evidence ++ [server_header, db_server_header])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    tech_info =
      if detected_tech_strings != [], do: Enum.join(detected_tech_strings, ", "), else: "none"

    Ravner.ActivityLog.emit(:step, "Fingerprinted technologies: #{tech_info}")

    # 4. Map detected technologies to Nuclei tags
    tech_tags = resolve_tech_tags(detected_tech_strings)

    # 4. Determine final tags to scan
    {mode, final_tags} =
      if tech_tags != [] do
        # We found specific technologies! Run a focused/profiled scan
        {:profiled, tech_tags}
      else
        # No specific technologies found. Use user's configured tags or a sensible default
        if config.nuclei_tags != [] do
          {:configured, config.nuclei_tags}
        else
          {:generic, ["cves", "misconfig", "exposure"]}
        end
      end

    # Log what mode and tags we are using
    case mode do
      :profiled ->
        Ravner.ActivityLog.emit(
          :step,
          "Running profiled Nuclei scan with tags: #{Enum.join(final_tags, ", ")}"
        )

      :configured ->
        Ravner.ActivityLog.emit(
          :step,
          "Running Nuclei scan with configured tags: #{Enum.join(final_tags, ", ")}"
        )

      :generic ->
        Ravner.ActivityLog.emit(
          :step,
          "No specific technologies matched. Running generic scan with tags: #{Enum.join(final_tags, ", ")}"
        )
    end

    # Build arguments for the scan
    severity_arg = Enum.join(config.nuclei_severities, ",")

    # Exclusions
    exclude_args =
      if config.nuclei_exclude_tags != [] do
        ["-etags", Enum.join(config.nuclei_exclude_tags, ",")]
      else
        []
      end

    # Lightweight/performance-optimized execution flags
    perf_flags = [
      "-disable-update-check",
      "-no-stdin",
      "-c",
      "10",
      "-mhe",
      "10",
      "-bulk-size",
      "10",
      "-rl",
      "100",
      "-timeout",
      "3",
      "-retries",
      "0",
      "-no-interactsh"
    ]

    args =
      [
        "-u",
        domain_name,
        "-severity",
        severity_arg,
        "-tags",
        Enum.join(final_tags, ","),
        "-jsonl",
        "-silent"
      ] ++
        exclude_args ++
        nuclei_template_flags() ++
        perf_flags

    case SystemCommand.run_with_timeout("nuclei", args, @nuclei_timeout) do
      {output, 0} ->
        {:ok, SecurityScans.parse_nuclei_output(output)}

      {:error, :timeout} ->
        {:error, "timed out after #{@nuclei_timeout}ms"}

      {:error, reason} ->
        {:error, reason}

      {output, code} ->
        {:error, "exited with code #{code}: #{String.slice(output, 0, 200)}"}
    end
  end

  defp resolve_tech_tags(detected_techs) do
    tags = []

    # 1. Java / Spring Boot
    tags =
      if matches_any?(detected_techs, ["java", "spring", "springboot", "log4j"]),
        do: ["spring", "springboot", "log4j", "java" | tags],
        else: tags

    # 2. WordPress
    tags =
      if matches_any?(detected_techs, ["wordpress", "wp", "wp-plugin"]),
        do: ["wordpress", "wp-plugin" | tags],
        else: tags

    # 3. PHP / Laravel
    tags =
      if matches_any?(detected_techs, ["php", "laravel", "thinkphp"]),
        do: ["php", "laravel", "thinkphp" | tags],
        else: tags

    # 4. Servers (Nginx, Apache, IIS)
    tags =
      if matches_any?(detected_techs, ["nginx"]),
        do: ["nginx", "http-header" | tags],
        else: tags

    tags =
      if matches_any?(detected_techs, ["apache", "httpd"]),
        do: ["apache", "http-header" | tags],
        else: tags

    tags =
      if matches_any?(detected_techs, ["iis", "microsoft-iis"]),
        do: ["iis", "http-header" | tags],
        else: tags

    # 5. Common panels & infrastructures
    tags =
      if matches_any?(detected_techs, ["cpanel", "whm"]),
        do: ["cpanel" | tags],
        else: tags

    tags =
      if matches_any?(detected_techs, ["coldfusion"]),
        do: ["coldfusion" | tags],
        else: tags

    tags =
      if matches_any?(detected_techs, ["django", "python"]),
        do: ["django", "python" | tags],
        else: tags

    tags =
      if matches_any?(detected_techs, ["drupal"]),
        do: ["drupal" | tags],
        else: tags

    tags =
      if matches_any?(detected_techs, ["joomla"]),
        do: ["joomla" | tags],
        else: tags

    tags =
      if matches_any?(detected_techs, ["magento"]),
        do: ["magento" | tags],
        else: tags

    tags =
      if matches_any?(detected_techs, ["rails", "ruby"]),
        do: ["rails", "ruby" | tags],
        else: tags

    tags =
      if matches_any?(detected_techs, ["tomcat"]),
        do: ["tomcat" | tags],
        else: tags

    Enum.uniq(tags)
  end

  defp matches_any?(list, patterns) do
    Enum.any?(list, fn item ->
      Enum.any?(patterns, &String.contains?(item, &1))
    end)
  end

  defp run_lonkero(domain_name) do
    temp_file = Path.join(System.tmp_dir!(), "lonkero_#{System.unique_integer([:positive])}.json")

    license_args =
      case Ravner.ApiKeys.get_effective_key("lonkero") do
        {_source, key, _} when is_binary(key) and key != "" ->
          ["-L", key]

        _ ->
          []
      end

    args =
      [
        "scan",
        domain_name,
        "-f",
        "json",
        "-o",
        temp_file,
        "--no-ml",
        "--concurrency",
        "10",
        "-q"
      ] ++ license_args

    case SystemCommand.run_with_timeout("lonkero", args, @nuclei_timeout) do
      {output, status} when is_integer(status) ->
        case File.read(temp_file) do
          {:ok, content} ->
            File.rm(temp_file)
            {:ok, SecurityScans.parse_lonkero_output(content)}

          {:error, _} ->
            if status == 0 do
              {:ok, []}
            else
              {:error, "exited with code #{status}: #{String.slice(output, 0, 200)}"}
            end
        end

      {:error, :timeout} ->
        File.rm(temp_file)
        {:error, "timed out after #{@nuclei_timeout}ms"}

      {:error, reason} ->
        File.rm(temp_file)
        {:error, reason}
    end
  end

  # ─── Output extraction ────────────────────────────────────────────────────

  defp extract_port_from_url(nil), do: []

  defp extract_port_from_url(url) do
    uri = URI.parse(url)

    case uri.port do
      nil -> []
      port -> [port]
    end
  end

  defp drop_empty(map) do
    map
    |> Enum.reject(fn
      {_k, nil} -> true
      {_k, ""} -> true
      {_k, []} -> true
      _ -> false
    end)
    |> Map.new()
  end

  defp extract_ports_from_naabu(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"port" => port}} when is_integer(port) -> [port]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp persist_metadata(_domain_id, attrs) when map_size(attrs) == 0, do: :ok

  defp persist_metadata(domain_id, attrs) do
    case Domains.upsert_domain_metadata(domain_id, attrs) do
      {:ok, _} ->
        Ravner.Governance.RiskScore.recalculate_for_domain(domain_id)
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Failed to upsert domain_metadata for #{domain_id}: #{inspect(changeset.errors)}"
        )

        :ok
    end
  end

  # ─── Binary / template helpers ────────────────────────────────────────────

  defp check_binary(name) do
    if System.find_executable(name) do
      :ok
    else
      {:error, "#{name} executable not found. Install it or use the container image."}
    end
  end

  @nuclei_template_paths [
    "/app/.nuclei-templates",
    "/app/nuclei-templates",
    "/root/nuclei-templates"
  ]

  defp nuclei_template_flags do
    case Enum.find(@nuclei_template_paths, &File.dir?/1) do
      nil -> []
      path -> ["-t", path]
    end
  end

  # ─── Scan lifecycle helpers ───────────────────────────────────────────────

  defp finalize_scan(scan, findings, raw_output, summary, liveview_pid) do
    # Wrap update + findings insert in a transaction to ensure atomicity
    result =
      Repo.transaction(fn ->
        case SecurityScans.update_scan(scan, %{
               status: "completed",
               completed_at: DateTime.utc_now(),
               progress: 100,
               raw_output: raw_output,
               summary: summary
             }) do
          {:ok, updated_scan} ->
            case SecurityScans.create_findings_batch(scan.id, findings) do
              {:ok, _count} -> updated_scan
              {:error, reason} -> Repo.rollback({:findings_insert_failed, reason})
            end

          {:error, changeset} ->
            Repo.rollback({:scan_update_failed, changeset})
        end
      end)

    case result do
      {:ok, updated_scan} ->
        # Prune old scans now that we have a fresh successful one
        SecurityScans.prune_old_scans(scan.domain_id)

        # Recalculate cyber risk score with newly committed findings and scan attributes
        Ravner.Governance.RiskScore.recalculate_for_domain(scan.domain_id)

        Ravner.ActivityLog.emit(:done, "Security scan done — #{summary}")

        final_scan = SecurityScans.get_scan!(updated_scan.id)

        if is_pid(liveview_pid),
          do: send(liveview_pid, {:scan_done, :security_scan, {:ok, final_scan}})

        {:ok, final_scan}

      {:error, reason} ->
        Logger.error("Failed to finalize scan #{scan.id}: #{inspect(reason)}")
        fail_scan(scan, "Failed to save scan results", liveview_pid)
    end
  end

  defp fail_scan(scan, message, liveview_pid) do
    Logger.warning("Security scan #{scan.id} failed: #{message}")

    # Truncate error message to keep DB/UI readable (500 chars max)
    truncated_message = truncate_error(message, 500)

    SecurityScans.update_scan(scan, %{
      status: "failed",
      completed_at: DateTime.utc_now(),
      progress: 100,
      error_message: truncated_message
    })

    if is_pid(liveview_pid),
      do: send(liveview_pid, {:scan_done, :security_scan, {:error, truncated_message}})

    {:error, truncated_message}
  end

  # Truncate error messages to keep them readable
  defp truncate_error(msg, max_len) when is_binary(msg) and byte_size(msg) > max_len do
    String.slice(msg, 0, max_len - 3) <> "..."
  end

  defp truncate_error(msg, _max_len) when is_binary(msg), do: msg
  defp truncate_error(msg, _max_len), do: inspect(msg) |> String.slice(0, 500)
end
