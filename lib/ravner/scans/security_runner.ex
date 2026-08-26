defmodule Ravner.Scans.SecurityRunner do
  @moduledoc """
  On-demand lean security scanner.

  A single `run_security_scan/2` entry point chains:

      httpx (tech detect, status, server, CDN)
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

  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Repo
  alias Ravner.SecurityScans
  alias Ravner.SecurityScans.SecurityScan
  alias Ravner.SystemCommand

  @scan_timeout 300_000
  @nuclei_timeout 240_000

  # ─── Public API ───────────────────────────────────────────────────────────

  @doc """
  Runs the lean security scan (httpx → naabu → nuclei) for a domain.

  Persists findings, upserts derived metadata into `domain_metadata`, and
  reports `{:scan_progress, ...}` / `{:scan_done, :security_scan, ...}` to
  the calling LiveView pid.
  """
  @spec run_security_scan(integer(), pid(), integer() | nil) ::
          {:ok, SecurityScan.t()} | {:error, String.t()}
  def run_security_scan(domain_id, liveview_pid, user_id \\ nil) do
    with {:ok, domain} <- fetch_domain_for_scan(domain_id),
         {:ok, scan} <- create_security_scan(domain_id, "security_scan", domain.name) do
      send_progress(scan.id, 5, liveview_pid)

      Task.Supervisor.start_child(Ravner.ScanTaskSupervisor, fn ->
        if user_id, do: Ravner.ActivityLog.set_user(user_id)
        do_security_scan(scan, domain.name, liveview_pid)
      end)

      {:ok, scan}
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
    SecurityScans.create_scan(%{
      domain_id: domain_id,
      tool: tool,
      status: "running",
      target: target,
      started_at: DateTime.utc_now()
    })
  end

  defp send_progress(scan_id, progress, liveview_pid) do
    # Persist progress to DB so UI re-fetches correct state
    case Repo.get(SecurityScan, scan_id) do
      nil -> :ok
      scan -> SecurityScans.update_scan(scan, %{progress: progress})
    end

    send(liveview_pid, {:scan_progress, scan_id, progress})
  end

  # ─── Lean security scan runner ────────────────────────────────────────────

  defp do_security_scan(scan, domain_name, liveview_pid) do
    send_progress(scan.id, 5, liveview_pid)
    config = Ravner.ScanConfig.get()
    active_scanner = config.security_scanner

    with :ok <- check_binary("httpx"),
         :ok <- check_binary("naabu"),
         :ok <- check_binary(active_scanner) do
      run_pipeline(scan, domain_name, liveview_pid, config)
    else
      {:error, reason} -> fail_scan(scan, reason, liveview_pid)
    end
  rescue
    ErlangError ->
      fail_scan(scan, "scanner executable not found or failed to run", liveview_pid)

    e ->
      fail_scan(scan, "unexpected error during scan: #{inspect(e)}", liveview_pid)
  end

  defp run_pipeline(scan, domain_name, liveview_pid, config) do
    # Phase 1: httpx (tech, status, server, CDN, redirect)
    Ravner.ActivityLog.emit(:step, "Security — HTTP fingerprinting #{domain_name}…")
    send_progress(scan.id, 10, liveview_pid)
    {httpx_output, httpx_metadata} = run_httpx(domain_name)

    server = httpx_metadata[:server_header]
    tech = httpx_metadata[:tech_stack] || []

    if server || tech != [] do
      tech_info = if tech != [], do: " [#{Enum.join(tech, ", ")}]", else: ""
      Ravner.ActivityLog.emit(:step, "Detected: #{server || "unknown server"}#{tech_info}")
    end

    # Phase 2: naabu port discovery
    Ravner.ActivityLog.emit(:step, "Security — port scanning #{domain_name} (top 100)…")
    send_progress(scan.id, 35, liveview_pid)

    case run_naabu(domain_name) do
      {:ok, naabu_output, ports} ->
        naabu_findings = SecurityScans.parse_naabu_output(naabu_output)

        # Fallback: if naabu finds nothing (SYN blocked by firewall) but httpx
        # detected a port, include the httpx-observed port
        ports =
          if ports == [] do
            extract_httpx_port(httpx_output)
          else
            ports
          end

        port_info = if ports != [], do: ": #{Enum.join(ports, ", ")}", else: ""
        Ravner.ActivityLog.emit(:step, "Found #{length(ports)} open ports#{port_info}")

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

      {:error, reason} ->
        Ravner.ActivityLog.emit(:error, "Port scan failed: #{reason}")
        fail_scan(scan, "naabu: #{reason}", liveview_pid)
    end
  end

  # ─── Phase implementations ────────────────────────────────────────────────

  defp run_httpx(domain_name) do
    args = [
      "-u",
      domain_name,
      "-json",
      "-silent",
      "-tech-detect",
      "-status-code",
      "-server",
      "-cdn",
      "-follow-redirects",
      "-location"
    ]

    case SystemCommand.run_with_timeout("httpx", args, @scan_timeout) do
      {output, 0} ->
        {output, extract_httpx_metadata(output)}

      _ ->
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
      "100"
    ]

    case SystemCommand.run_with_timeout("naabu", args, @scan_timeout) do
      {output, 0} ->
        {:ok, output, extract_ports_from_naabu(output)}

      {:error, :timeout} ->
        {:error, "timed out after #{@scan_timeout}ms"}

      {:error, reason} ->
        {:error, reason}

      {output, code} ->
        {:error, "exited with code #{code}: #{String.slice(output, 0, 200)}"}
    end
  end

  defp run_nuclei(domain_id, domain_name, config, httpx_metadata) do
    # 1. Gather technologies from HTTPX metadata
    httpx_techs = Map.get(httpx_metadata, :tech_stack, [])
    server_header = Map.get(httpx_metadata, :server_header, "")

    # 2. Gather technologies from the DB (DomainMetadata + TechEvidence)
    import Ecto.Query

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

    # 3. Run a quick Nuclei fingerprinting scan to detect additional technologies
    fingerprint_techs = run_nuclei_fingerprint(domain_name)

    # Combine all detected technology strings
    detected_tech_strings =
      (httpx_techs ++
         db_tech_stack ++
         db_tech_evidence ++ fingerprint_techs ++ [server_header, db_server_header])
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

  defp run_nuclei_fingerprint(domain_name) do
    args =
      [
        "-u",
        domain_name,
        "-tags",
        "tech",
        "-severity",
        "info",
        "-jsonl",
        "-silent",
        "-timeout",
        "3",
        "-retries",
        "0",
        "-no-interactsh",
        "-c",
        "10",
        "-rl",
        "100"
      ] ++ nuclei_template_flags()

    case SystemCommand.run_with_timeout("nuclei", args, 30_000) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, data} ->
              template_id = data["template-id"] || ""
              name = get_in(data, ["info", "name"]) || ""
              tags = get_in(data, ["info", "tags"]) || []
              [template_id, name | tags]

            _ ->
              []
          end
        end)
        |> Enum.uniq()

      _ ->
        []
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

  defp extract_httpx_port(httpx_output) do
    httpx_output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"port" => port}} when is_binary(port) ->
          case Integer.parse(port) do
            {p, _} -> [p]
            _ -> []
          end

        {:ok, %{"port" => port}} when is_integer(port) ->
          [port]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp extract_httpx_metadata(httpx_output) do
    httpx_output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, data} when is_map(data) -> [data]
        _ -> []
      end
    end)
    |> case do
      [] ->
        %{}

      [data | _] ->
        %{
          tech_stack: data |> Map.get("tech") |> List.wrap() |> Enum.uniq(),
          http_status: data["status-code"] || data["status_code"],
          final_url: data["final-url"] || data["url"],
          server_header: data["webserver"] || data["server"],
          hosting_platform: data["cdn-name"] || data["cdn_name"]
        }
        |> drop_empty()
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
    {:ok, updated_scan} =
      SecurityScans.update_scan(scan, %{
        status: "completed",
        completed_at: DateTime.utc_now(),
        progress: 100,
        raw_output: raw_output,
        summary: summary
      })

    SecurityScans.create_findings_batch(scan.id, findings)

    # Prune old scans now that we have a fresh successful one
    SecurityScans.prune_old_scans(scan.domain_id)

    Ravner.ActivityLog.emit(:done, "Security scan done — #{summary}")

    final_scan = SecurityScans.get_scan!(updated_scan.id)
    send(liveview_pid, {:scan_done, :security_scan, {:ok, final_scan}})
  end

  defp fail_scan(scan, message, liveview_pid) do
    Logger.warning("Security scan #{scan.id} failed: #{message}")

    SecurityScans.update_scan(scan, %{
      status: "failed",
      completed_at: DateTime.utc_now(),
      progress: 100,
      error_message: message
    })

    send(liveview_pid, {:scan_done, :security_scan, {:error, message}})
  end
end
