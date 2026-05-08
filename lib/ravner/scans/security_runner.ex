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

  @scan_timeout 300_000
  @nuclei_timeout 240_000

  # Common nuclei flags to keep runs predictable inside our timeout budget:
  # disable self/template update probes, refuse to read stdin, cap concurrency
  # and request rate so we don't get throttled or run wildly long. `-mhe`
  # mirrors `-c` so nuclei doesn't warn about concurrency > max-host-error.
  @nuclei_perf_flags [
    "-disable-update-check",
    "-no-stdin",
    "-c",
    "50",
    "-mhe",
    "50",
    "-bulk-size",
    "25",
    "-rl",
    "200"
  ]

  # ─── Public API ───────────────────────────────────────────────────────────

  @doc """
  Runs the lean security scan (httpx → naabu → nuclei) for a domain.

  Persists findings, upserts derived metadata into `domain_metadata`, and
  reports `{:scan_progress, ...}` / `{:scan_done, :security_scan, ...}` to
  the calling LiveView pid.
  """
  @spec run_security_scan(integer(), pid()) ::
          {:ok, SecurityScan.t()} | {:error, String.t()}
  def run_security_scan(domain_id, liveview_pid) do
    with {:ok, domain} <- fetch_domain_for_scan(domain_id),
         {:ok, scan} <- create_security_scan(domain_id, "security_scan", domain.name) do
      send_progress(scan.id, 5, liveview_pid)

      Task.Supervisor.start_child(Ravner.ScanTaskSupervisor, fn ->
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

    with :ok <- check_binary("httpx"),
         :ok <- check_binary("naabu"),
         :ok <- check_binary("nuclei") do
      run_pipeline(scan, domain_name, liveview_pid)
    else
      {:error, reason} -> fail_scan(scan, reason, liveview_pid)
    end
  rescue
    ErlangError ->
      fail_scan(scan, "scanner executable not found or failed to run", liveview_pid)

    e ->
      fail_scan(scan, "unexpected error during scan: #{inspect(e)}", liveview_pid)
  end

  defp run_pipeline(scan, domain_name, liveview_pid) do
    # Phase 1: httpx (tech, status, server, CDN, redirect)
    send_progress(scan.id, 10, liveview_pid)
    {httpx_output, httpx_metadata} = run_httpx(domain_name)

    # Phase 2: naabu port discovery
    send_progress(scan.id, 35, liveview_pid)

    case run_naabu(domain_name) do
      {:ok, naabu_output, ports} ->
        naabu_findings = SecurityScans.parse_naabu_output(naabu_output)

        # Phase 3: lightweight nuclei against the HTTP/HTTPS surface only
        # Templates are pre-baked in the Docker image. Manual updates available via admin settings.
        send_progress(scan.id, 60, liveview_pid)

        case run_nuclei(domain_name) do
          {:ok, nuclei_findings} ->
            send_progress(scan.id, 90, liveview_pid)

            summary =
              "#{length(ports)} open ports, " <>
                "#{length(nuclei_findings)} critical/high findings"

            metadata_attrs =
              httpx_metadata
              |> Map.put(:open_ports, ports)
              |> Map.put(:last_security_scan_at, DateTime.utc_now())

            persist_metadata(scan.domain_id, metadata_attrs)

            finalize_scan(
              scan,
              naabu_findings ++ nuclei_findings,
              naabu_output <> "\n---\n" <> httpx_output,
              summary,
              liveview_pid
            )

          {:error, reason} ->
            fail_scan(scan, "nuclei: #{reason}", liveview_pid)
        end

      {:error, reason} ->
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

    case cmd_with_timeout("httpx", args, [stderr_to_stdout: true], @scan_timeout) do
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

    case cmd_with_timeout("naabu", args, [stderr_to_stdout: true], @scan_timeout) do
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

  defp run_nuclei(domain_name) do
    # Phase 1: framework-specific + severity filter for targeted scan
    # (WordPress, Drupal, PHP, Node.js, Django, FastAPI, etc.)
    framework_tags = "wordpress,drupal,php,nodejs,express,django,fastapi,astro,nextjs"

    args =
      [
        "-u",
        domain_name,
        "-tags",
        framework_tags,
        "-severity",
        "critical,high",
        "-jsonl",
        "-silent",
        "-timeout",
        "10"
      ] ++ @nuclei_perf_flags

    case cmd_with_timeout("nuclei", args, [stderr_to_stdout: true], @nuclei_timeout) do
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

  # ─── Output extraction ────────────────────────────────────────────────────

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

  # ─── Timeout wrapper for spawned scanner CLIs ─────────────────────────────
  #
  # `System.cmd/3` + `Task.shutdown` only kills the BEAM-side Task: the bash
  # subprocess and any descendants (naabu/nuclei/httpx and their helpers) keep
  # running as orphans on the host. To avoid leaking processes when we hit a
  # timeout, we:
  #
  #   1. Spawn a Port directly so we know the OS PID we created.
  #   2. Wrap the command in a Perl one-liner that calls `POSIX::setsid()` and
  #      then `exec`s into bash. That places the entire command tree in a fresh
  #      process group whose PGID equals the Port's OS PID (Perl's PID is
  #      preserved across `exec`).
  #   3. On timeout, send SIGTERM (then SIGKILL) to the negative PGID so the
  #      whole group, including grandchildren spawned by the scanner, dies.
  #
  # Perl is used instead of `setsid(1)` because the latter is not present on
  # macOS by default; Perl ships on every supported dev/runtime platform.

  @spec cmd_with_timeout(String.t(), [String.t()], keyword(), non_neg_integer()) ::
          {String.t(), non_neg_integer()} | {:error, :timeout} | {:error, String.t()}
  defp cmd_with_timeout(cmd, args, _opts, timeout) do
    # naabu and other PD tools hang when stdin is a terminal.
    # `</dev/null` forces immediate EOF on stdin; `exec` drops the bash layer.
    shell_cmd = "exec #{cmd} #{escape_args(args)} </dev/null"

    perl_script = "use POSIX qw(setsid); setsid(); exec @ARGV"

    case System.find_executable("perl") do
      nil ->
        {:error, "perl not found (required for process group isolation)"}

      perl_path ->
        port =
          Port.open(
            {:spawn_executable, perl_path},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: ["-e", perl_script, "--", "/bin/bash", "-c", shell_cmd]
            ]
          )

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        deadline = System.monotonic_time(:millisecond) + timeout

        case collect_port_output(port, deadline, "") do
          {:ok, output, status} ->
            {output, status}

          :timeout ->
            if os_pid, do: kill_process_group(os_pid)
            close_port(port)
            {:error, :timeout}
        end
    end
  end

  defp collect_port_output(port, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, deadline, acc <> data)

      {^port, {:exit_status, status}} ->
        {:ok, acc, status}
    after
      remaining ->
        :timeout
    end
  end

  defp kill_process_group(os_pid) do
    pgid_arg = "-#{os_pid}"
    _ = System.cmd("kill", ["-TERM", "--", pgid_arg], stderr_to_stdout: true)
    Process.sleep(500)
    _ = System.cmd("kill", ["-KILL", "--", pgid_arg], stderr_to_stdout: true)
    :ok
  end

  defp close_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  defp escape_args(args) do
    args
    |> Enum.map(fn arg ->
      if String.match?(arg, ~r/^[a-zA-Z0-9_.~+=@-]+$/) do
        arg
      else
        escaped = String.replace(arg, "'", "'\"'\"'")
        "'" <> escaped <> "'"
      end
    end)
    |> Enum.join(" ")
  end
end
