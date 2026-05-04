defmodule Ravner.Scans.SecurityRunner do
  @moduledoc """
  On-demand security scanner runners for Naabu, Nuclei, and httpx.

  Each runner executes the underlying CLI tool via `System.cmd/3`, parses the
  JSON/JSONL output, persists findings through `Ravner.SecurityScans`, and
  reports progress back to the calling LiveView process.
  """

  require Logger

  alias Ravner.Domains.Domain
  alias Ravner.Repo
  alias Ravner.SecurityScans
  alias Ravner.SecurityScans.SecurityScan

  @nuclei_tags "http,ssl,exposure"
  @scan_timeout 300_000
  @template_update_timeout 180_000

  # ─── Public API ───────────────────────────────────────────────────────────

  @doc """
  Runs a Naabu port scan for a domain and persists results.

  Returns the created `SecurityScan` record on success.
  """
  @spec run_naabu_scan(integer(), pid()) ::
          {:ok, SecurityScan.t()} | {:error, String.t()}
  def run_naabu_scan(domain_id, liveview_pid) do
    with {:ok, domain} <- fetch_domain_for_scan(domain_id),
         {:ok, scan} <- create_security_scan(domain_id, "naabu", domain.name) do
      send_progress(scan.id, 5, liveview_pid)

      Task.start(fn ->
        do_naabu_scan(scan, domain.name, liveview_pid)
      end)

      {:ok, scan}
    end
  end

  @doc """
  Runs a Nuclei vulnerability scan for a domain and persists results.

  Returns the created `SecurityScan` record on success.
  """
  @spec run_nuclei_scan(integer(), pid()) ::
          {:ok, SecurityScan.t()} | {:error, String.t()}
  def run_nuclei_scan(domain_id, liveview_pid) do
    with {:ok, domain} <- fetch_domain_for_scan(domain_id),
         {:ok, scan} <- create_security_scan(domain_id, "nuclei", domain.name) do
      send_progress(scan.id, 5, liveview_pid)

      Task.start(fn ->
        do_nuclei_scan(scan, domain.name, liveview_pid)
      end)

      {:ok, scan}
    end
  end

  @doc """
  Runs an httpx binary probe for a domain and persists results.

  Returns the created `SecurityScan` record on success.
  """
  @spec run_httpx_binary_scan(integer(), pid()) ::
          {:ok, SecurityScan.t()} | {:error, String.t()}
  def run_httpx_binary_scan(domain_id, liveview_pid) do
    with {:ok, domain} <- fetch_domain_for_scan(domain_id),
         {:ok, scan} <- create_security_scan(domain_id, "httpx", domain.name) do
      send_progress(scan.id, 5, liveview_pid)

      Task.start(fn ->
        do_httpx_binary_scan(scan, domain.name, liveview_pid)
      end)

      {:ok, scan}
    end
  end

  @doc """
  Runs a deep scan: Naabu discovers ports, then Nuclei scans each port.

  Returns the created `SecurityScan` record on success.
  """
  @spec run_deep_scan(integer(), pid()) ::
          {:ok, SecurityScan.t()} | {:error, String.t()}
  def run_deep_scan(domain_id, liveview_pid) do
    with {:ok, domain} <- fetch_domain_for_scan(domain_id),
         {:ok, scan} <- create_security_scan(domain_id, "deep_scan", domain.name) do
      send_progress(scan.id, 5, liveview_pid)

      Task.start(fn ->
        do_deep_scan(scan, domain.name, liveview_pid)
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
    send(liveview_pid, {:scan_progress, scan_id, progress})
  end

  # ─── Naabu runner ─────────────────────────────────────────────────────────

  defp do_naabu_scan(scan, domain_name, liveview_pid) do
    send_progress(scan.id, 10, liveview_pid)

    case check_binary("naabu") do
      {:error, reason} ->
        fail_scan(scan, reason, liveview_pid, :naabu)

      :ok ->
        send_progress(scan.id, 25, liveview_pid)

        args = [
          "-host",
          domain_name,
          "-json",
          "-silent",
          "-stream",
          "-top-ports",
          "100"
        ]

        case cmd_with_timeout("naabu", args,
               [stderr_to_stdout: true],
               @scan_timeout
             ) do
          {output, 0} ->
            send_progress(scan.id, 75, liveview_pid)
            findings = SecurityScans.parse_naabu_output(output)
            complete_scan(scan, findings, output, liveview_pid, :naabu)

          {:error, :timeout} ->
            fail_scan(scan, "naabu timed out after #{@scan_timeout}ms", liveview_pid, :naabu)

          {output, code} ->
            fail_scan(
              scan,
              "naabu exited with code #{code}: #{String.slice(output, 0, 200)}",
              liveview_pid,
              :naabu
            )
        end
    end
  rescue
    ErlangError ->
      fail_scan(scan, "naabu executable not found or failed to run", liveview_pid, :naabu)
  end

  # ─── Nuclei runner ────────────────────────────────────────────────────────

  defp do_nuclei_scan(scan, domain_name, liveview_pid) do
    send_progress(scan.id, 10, liveview_pid)

    case check_binary("nuclei") do
      {:error, reason} ->
        fail_scan(scan, reason, liveview_pid, :nuclei)

      :ok ->
        maybe_update_nuclei_templates(scan, liveview_pid)
        send_progress(scan.id, 30, liveview_pid)

        args = [
          "-u",
          domain_name,
          "-tags",
          @nuclei_tags,
          "-jsonl",
          "-silent",
          "-timeout",
          "10"
        ]

        case cmd_with_timeout("nuclei", args,
               [stderr_to_stdout: true],
               @scan_timeout
             ) do
          {output, 0} ->
            send_progress(scan.id, 85, liveview_pid)
            findings = SecurityScans.parse_nuclei_output(output)
            complete_scan(scan, findings, output, liveview_pid, :nuclei)

          {:error, :timeout} ->
            fail_scan(scan, "nuclei timed out after #{@scan_timeout}ms", liveview_pid, :nuclei)

          {output, code} ->
            fail_scan(
              scan,
              "nuclei exited with code #{code}: #{String.slice(output, 0, 200)}",
              liveview_pid,
              :nuclei
            )
        end
    end
  rescue
    ErlangError ->
      fail_scan(scan, "nuclei executable not found or failed to run", liveview_pid, :nuclei)
  end

  # ─── httpx runner ─────────────────────────────────────────────────────────

  defp do_httpx_binary_scan(scan, domain_name, liveview_pid) do
    send_progress(scan.id, 10, liveview_pid)

    case check_binary("httpx") do
      {:error, reason} ->
        fail_scan(scan, reason, liveview_pid, :httpx_binary)

      :ok ->
        send_progress(scan.id, 30, liveview_pid)

        args = [
          "-u",
          domain_name,
          "-json",
          "-silent",
          "-title",
          "-tech-detect",
          "-status-code"
        ]

        case cmd_with_timeout("httpx", args,
               [stderr_to_stdout: true],
               @scan_timeout
             ) do
          {output, 0} ->
            send_progress(scan.id, 85, liveview_pid)
            findings = SecurityScans.parse_httpx_output(output)
            complete_scan(scan, findings, output, liveview_pid, :httpx_binary)

          {:error, :timeout} ->
            fail_scan(scan, "httpx timed out after #{@scan_timeout}ms", liveview_pid, :httpx_binary)

          {output, code} ->
            fail_scan(
              scan,
              "httpx exited with code #{code}: #{String.slice(output, 0, 200)}",
              liveview_pid,
              :httpx_binary
            )
        end
    end
  rescue
    ErlangError ->
      fail_scan(scan, "httpx executable not found or failed to run", liveview_pid, :httpx_binary)
  end

  # ─── Deep scan runner ─────────────────────────────────────────────────────

  defp do_deep_scan(scan, domain_name, liveview_pid) do
    send_progress(scan.id, 5, liveview_pid)

    with :ok <- check_binary("naabu"),
         :ok <- check_binary("nuclei") do
      # Phase 1: Naabu port discovery
      send_progress(scan.id, 10, liveview_pid)

      naabu_args = [
        "-host",
        domain_name,
        "-json",
        "-silent",
        "-stream",
        "-top-ports",
        "100"
      ]

      case cmd_with_timeout("naabu", naabu_args,
             [stderr_to_stdout: true],
             @scan_timeout
           ) do
        {naabu_output, 0} ->
          send_progress(scan.id, 40, liveview_pid)
          ports = extract_ports_from_naabu(naabu_output)

          if ports == [] do
            # No ports found — complete with just naabu results
            findings = SecurityScans.parse_naabu_output(naabu_output)
            complete_scan(scan, findings, naabu_output, liveview_pid, :deep_scan)
          else
            # Phase 2: Nuclei on each discovered port
            maybe_update_nuclei_templates(scan, liveview_pid)
            send_progress(scan.id, 50, liveview_pid)

            all_findings = SecurityScans.parse_naabu_output(naabu_output)

            total = length(ports)

            ports
            |> Enum.with_index(1)
            |> Enum.each(fn {port, idx} ->
              target = "#{domain_name}:#{port}"
              progress = 50 + div(idx * 40, total)
              send_progress(scan.id, progress, liveview_pid)

              nuclei_args = [
                "-u",
                target,
                "-tags",
                @nuclei_tags,
                "-jsonl",
                "-silent",
                "-timeout",
                "10"
              ]

              case cmd_with_timeout("nuclei", nuclei_args,
                     [stderr_to_stdout: true],
                     @scan_timeout
                   ) do
                {output, 0} ->
                  findings = SecurityScans.parse_nuclei_output(output)
                  insert_findings(scan, findings)

                _ ->
                  :ok
              end
            end)

            # Reload findings from DB after all nuclei runs
            updated_findings = SecurityScans.list_findings_for_scan(scan.id)

            summary =
              "#{length(all_findings)} ports, #{count_nuclei_findings(updated_findings)} nuclei findings"

            finalize_scan(scan, updated_findings, naabu_output, summary, liveview_pid, :deep_scan)
          end

        {:error, :timeout} ->
          fail_scan(scan, "naabu timed out after #{@scan_timeout}ms", liveview_pid, :deep_scan)

        {output, code} ->
          fail_scan(
            scan,
            "naabu exited with code #{code}: #{String.slice(output, 0, 200)}",
            liveview_pid,
            :deep_scan
          )
      end
    else
      {:error, reason} -> fail_scan(scan, reason, liveview_pid, :deep_scan)
    end
  rescue
    ErlangError ->
      fail_scan(
        scan,
        "scanner executable not found or failed to run",
        liveview_pid,
        :deep_scan
      )
  end

  defp extract_ports_from_naabu(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"port" => port}} -> [port]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp count_nuclei_findings(findings) do
    findings
    |> Enum.reject(fn f -> is_nil(f.detail["template-id"]) end)
    |> length()
  end

  # ─── Binary / template helpers ────────────────────────────────────────────

  defp check_binary(name) do
    if System.find_executable(name) do
      :ok
    else
      {:error, "#{name} executable not found. Install it or use the container image."}
    end
  end

  defp maybe_update_nuclei_templates(scan, liveview_pid) do
    templates_dir = Path.join(System.user_home!(), ".nuclei-templates")

    unless File.exists?(templates_dir) do
      send_progress(scan.id, 15, liveview_pid)
      Logger.info("Updating Nuclei templates for the first time...")

      case cmd_with_timeout("nuclei", ["-update-templates"],
             [stderr_to_stdout: true],
             @template_update_timeout
           ) do
        {_, 0} ->
          Logger.info("Nuclei templates updated successfully")
          :ok

        {output, code} ->
          Logger.warning("Nuclei template update exited #{code}: #{String.slice(output, 0, 200)}")

          :ok
      end
    end
  end

  # ─── Scan lifecycle helpers ───────────────────────────────────────────────

  defp complete_scan(scan, findings, raw_output, liveview_pid, tool) do
    send_progress(scan.id, 95, liveview_pid)

    summary =
      case scan.tool do
        "naabu" -> "#{length(findings)} open ports found"
        "nuclei" -> "#{length(findings)} potential issues found"
        "httpx" -> "#{length(findings)} responses probed"
        _ -> "#{length(findings)} findings"
      end

    finalize_scan(scan, findings, raw_output, summary, liveview_pid, tool)
  end

  defp finalize_scan(scan, findings, raw_output, summary, liveview_pid, tool) do
    SecurityScans.update_scan(scan, %{
      status: "completed",
      completed_at: DateTime.utc_now(),
      progress: 100,
      raw_output: raw_output,
      summary: summary
    })

    insert_findings(scan, findings)

    updated_scan = SecurityScans.get_scan!(scan.id)
    send(liveview_pid, {:scan_done, tool, {:ok, updated_scan}})
  end

  defp fail_scan(scan, message, liveview_pid, tool) do
    Logger.warning("Security scan #{scan.id} failed: #{message}")

    SecurityScans.update_scan(scan, %{
      status: "failed",
      completed_at: DateTime.utc_now(),
      progress: 100,
      error_message: message
    })

    send(liveview_pid, {:scan_done, tool, {:error, message}})
  end

  defp insert_findings(scan, findings) do
    Enum.each(findings, fn attrs ->
      SecurityScans.create_finding(Map.put(attrs, :security_scan_id, scan.id))
    end)
  end

  # ─── Timeout wrapper for System.cmd ───────────────────────────────────────

  @doc false
  @spec cmd_with_timeout(String.t(), [String.t()], keyword(), non_neg_integer()) ::
          {String.t(), non_neg_integer()} | {:error, :timeout}
  defp cmd_with_timeout(cmd, args, _opts, timeout) do
    # naabu and other PD tools hang when stdin is a terminal.
    # Wrap in bash with </dev/null to force immediate EOF on stdin.
    shell_cmd = "#{cmd} #{escape_args(args)} </dev/null"

    task =
      Task.async(fn ->
        System.cmd("bash", ["-c", shell_cmd], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
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
