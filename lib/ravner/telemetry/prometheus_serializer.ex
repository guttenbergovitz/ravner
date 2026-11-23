defmodule Ravner.Telemetry.PrometheusSerializer do
  @moduledoc """
  Serializes Ravner synthetic observability, inventory governance, and BEAM VM metrics
  into the OpenMetrics / Prometheus standard text exposition format (version 0.0.4).

  Complies with Prometheus exposition standards:
  - `# HELP <metric> <description>`
  - `# TYPE <metric> <counter|gauge|summary>`
  - `<metric>{<labels>} <value>`
  """

  alias Ravner.Telemetry.EventBuffer

  @doc """
  Generates the complete Prometheus scrape exposition text body.
  """
  @spec format() :: String.t()
  def format do
    buffer_stats = EventBuffer.stats()
    recent_events = EventBuffer.list()

    [
      format_header(),
      format_synthetic_buffer_metrics(buffer_stats),
      format_recent_probes(recent_events),
      format_inventory_metrics(),
      format_domain_governance_metrics(),
      format_lighthouse_metrics(),
      format_a11y_metrics(),
      format_repository_security_metrics(),
      format_vm_metrics()
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  # ── Section Formatters ─────────────────────────────────────────────────────

  defp format_header do
    """
    # ── Ravner Synthetic Observability & Governance Metrics ──
    # Exporter: Ravner Prometheus Exporter v1.0
    """
    |> String.trim()
  end

  defp format_synthetic_buffer_metrics(stats) do
    total = Map.get(stats, :total, 0)
    http_count = Map.get(stats, :http_count, 0)
    uptime_count = Map.get(stats, :uptime_count, 0)
    incident_count = Map.get(stats, :incident_count, 0)
    web_vitals_count = Map.get(stats, :web_vitals_count, 0)
    a11y_count = Map.get(stats, :a11y_count, 0)
    dns_count = Map.get(stats, :dns_count, 0)
    security_headers_count = Map.get(stats, :security_headers_count, 0)
    sca_count = Map.get(stats, :sca_count, 0)
    tls_count = Map.get(stats, :tls_count, 0)
    probe_count = Map.get(stats, :probe_count, 0)
    avg_latency = Map.get(stats, :avg_latency_ms, 0)
    error_count = Map.get(stats, :error_count, 0)
    vuln_count = Map.get(stats, :total_vulnerabilities, 0)

    """
    # HELP ravner_synthetic_events_total Total synthetic observability events processed
    # TYPE ravner_synthetic_events_total counter
    ravner_synthetic_events_total #{total}

    # HELP ravner_synthetic_probes_by_type_total Synthetic probe executions partitioned by category
    # TYPE ravner_synthetic_probes_by_type_total counter
    ravner_synthetic_probes_by_type_total{type="http"} #{http_count}
    ravner_synthetic_probes_by_type_total{type="uptime"} #{uptime_count}
    ravner_synthetic_probes_by_type_total{type="incident"} #{incident_count}
    ravner_synthetic_probes_by_type_total{type="web_vitals"} #{web_vitals_count}
    ravner_synthetic_probes_by_type_total{type="a11y"} #{a11y_count}
    ravner_synthetic_probes_by_type_total{type="dns"} #{dns_count}
    ravner_synthetic_probes_by_type_total{type="security_headers"} #{security_headers_count}
    ravner_synthetic_probes_by_type_total{type="sca"} #{sca_count}
    ravner_synthetic_probes_by_type_total{type="tls"} #{tls_count}
    ravner_synthetic_probes_by_type_total{type="probe"} #{probe_count}

    # HELP ravner_synthetic_http_avg_latency_ms Rolling average latency across recent probes in milliseconds
    # TYPE ravner_synthetic_http_avg_latency_ms gauge
    ravner_synthetic_http_avg_latency_ms #{avg_latency}

    # HELP ravner_synthetic_probe_errors_total Number of failed probes recorded in buffer
    # TYPE ravner_synthetic_probe_errors_total counter
    ravner_synthetic_probe_errors_total #{error_count}

    # HELP ravner_synthetic_vulnerabilities_tracked Total CVEs and vulnerabilities detected
    # TYPE ravner_synthetic_vulnerabilities_tracked gauge
    ravner_synthetic_vulnerabilities_tracked #{vuln_count}
    """
    |> String.trim()
  end

  defp format_recent_probes(events) do
    # Deduplicate recent events per server.address
    per_host =
      events
      |> Enum.reject(&is_nil(&1.metadata["server.address"]))
      |> Enum.group_by(& &1.metadata["server.address"])
      |> Enum.map(fn {host, host_events} ->
        {host, List.first(host_events)}
      end)

    if per_host == [] do
      ""
    else
      status_lines =
        Enum.map(per_host, fn {host, ev} ->
          is_up =
            cond do
              ev.metadata["is_up"] != nil ->
                if(ev.metadata["is_up"], do: 1, else: 0)

              ev.metadata["http.response.status_code"] ->
                if(ev.metadata["http.response.status_code"] < 400, do: 1, else: 0)

              true ->
                1
            end

          ~s(ravner_domain_status{server_address="#{escape_label(host)}"} #{is_up})
        end)
        |> Enum.join("\n")

      latency_lines =
        per_host
        |> Enum.filter(fn {_host, ev} ->
          ev.measurements[:duration_ms] || ev.measurements[:response_time_ms]
        end)
        |> Enum.map(fn {host, ev} ->
          latency = ev.measurements[:duration_ms] || ev.measurements[:response_time_ms]
          ~s(ravner_domain_latency_ms{server_address="#{escape_label(host)}"} #{latency})
        end)
        |> Enum.join("\n")

      [
        """
        # HELP ravner_domain_status Latest availability status per monitored target (1=up, 0=down)
        # TYPE ravner_domain_status gauge
        #{status_lines}
        """
        |> String.trim(),
        if(latency_lines != "",
          do:
            """
            # HELP ravner_domain_latency_ms Most recent probe latency per target in milliseconds
            # TYPE ravner_domain_latency_ms gauge
            #{latency_lines}
            """
            |> String.trim(),
          else: ""
        )
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
    end
  end

  defp format_inventory_metrics do
    try do
      import Ecto.Query
      alias Ravner.Domains.Domain
      alias Ravner.Domains.DomainMetadata

      total = Ravner.Repo.aggregate(Domain, :count, :id) || 0

      up_count =
        Ravner.Repo.one(
          from(m in DomainMetadata,
            where: m.is_up == true,
            select: count(m.id)
          )
        ) || 0

      down_count =
        Ravner.Repo.one(
          from(m in DomainMetadata,
            where: m.is_up == false,
            select: count(m.id)
          )
        ) || 0

      """
      # HELP ravner_inventory_domains_total Total domains registered in governance inventory
      # TYPE ravner_inventory_domains_total gauge
      ravner_inventory_domains_total #{total}

      # HELP ravner_inventory_domains_up_total Number of registered domains in healthy UP state
      # TYPE ravner_inventory_domains_up_total gauge
      ravner_inventory_domains_up_total #{up_count}

      # HELP ravner_inventory_domains_down_total Number of registered domains currently DOWN
      # TYPE ravner_inventory_domains_down_total gauge
      ravner_inventory_domains_down_total #{down_count}
      """
      |> String.trim()
    rescue
      _ -> ""
    end
  end

  defp format_domain_governance_metrics do
    try do
      import Ecto.Query
      alias Ravner.Domains.Domain
      alias Ravner.Domains.DomainMetadata

      rows =
        Ravner.Repo.all(
          from(d in Domain,
            join: m in DomainMetadata,
            on: m.domain_id == d.id,
            where:
              not is_nil(m.ssl_days_remaining) or not is_nil(m.risk_score) or
                not is_nil(m.is_up),
            select: %{
              domain: d.name,
              ssl_days_remaining: m.ssl_days_remaining,
              risk_score: m.risk_score,
              risk_grade: m.risk_grade,
              is_up: m.is_up
            }
          )
        )

      ssl_lines =
        rows
        |> Enum.reject(&is_nil(&1.ssl_days_remaining))
        |> Enum.map(fn row ->
          ~s(ravner_domain_ssl_days_remaining{domain="#{escape_label(row.domain)}"} #{row.ssl_days_remaining})
        end)

      risk_lines =
        rows
        |> Enum.reject(&is_nil(&1.risk_score))
        |> Enum.map(fn row ->
          grade = row.risk_grade || "unknown"

          ~s(ravner_domain_risk_score{domain="#{escape_label(row.domain)}",grade="#{escape_label(grade)}"} #{row.risk_score})
        end)

      up_lines =
        rows
        |> Enum.reject(&is_nil(&1.is_up))
        |> Enum.map(fn row ->
          val = if(row.is_up, do: 1, else: 0)
          ~s(ravner_domain_up{domain="#{escape_label(row.domain)}"} #{val})
        end)

      [
        format_metric_block(
          "ravner_domain_up",
          "gauge",
          "Persisted domain availability status from latest check (1=up, 0=down)",
          up_lines
        ),
        format_metric_block(
          "ravner_domain_ssl_days_remaining",
          "gauge",
          "Days remaining until SSL/TLS certificate expiration per domain",
          ssl_lines
        ),
        format_metric_block(
          "ravner_domain_risk_score",
          "gauge",
          "Calculated governance risk score (0-100) per domain",
          risk_lines
        )
      ]
      |> join_metric_blocks()
    rescue
      _ -> ""
    end
  end

  defp format_lighthouse_metrics do
    try do
      import Ecto.Query
      alias Ravner.Domains.Domain
      alias Ravner.Lighthouse.LighthouseScan

      latest_scans =
        Ravner.Repo.all(
          from(l in LighthouseScan,
            join: d in Domain,
            on: d.id == l.domain_id,
            where: l.status == "completed",
            distinct: l.domain_id,
            order_by: [asc: l.domain_id, desc: l.completed_at, desc: l.id],
            select: %{
              domain: d.name,
              performance_score: l.performance_score,
              accessibility_score: l.accessibility_score,
              best_practices_score: l.best_practices_score,
              seo_score: l.seo_score,
              fcp_ms: l.fcp_ms,
              lcp_ms: l.lcp_ms,
              tbt_ms: l.tbt_ms,
              speed_index_ms: l.speed_index_ms,
              cls: l.cls
            }
          )
        )

      score_categories = [
        {:performance_score, "performance"},
        {:accessibility_score, "accessibility"},
        {:best_practices_score, "best_practices"},
        {:seo_score, "seo"}
      ]

      score_lines =
        for scan <- latest_scans,
            {field, category} <- score_categories,
            val = Map.get(scan, field),
            not is_nil(val) do
          ~s(ravner_lighthouse_score{domain="#{escape_label(scan.domain)}",category="#{category}"} #{val})
        end

      vital_metrics = [
        {:fcp_ms, "fcp"},
        {:lcp_ms, "lcp"},
        {:tbt_ms, "tbt"},
        {:speed_index_ms, "speed_index"}
      ]

      vital_lines =
        for scan <- latest_scans,
            {field, metric} <- vital_metrics,
            val = Map.get(scan, field),
            not is_nil(val) do
          ~s(ravner_lighthouse_web_vital_ms{domain="#{escape_label(scan.domain)}",metric="#{metric}"} #{val})
        end

      cls_lines =
        latest_scans
        |> Enum.reject(&is_nil(&1.cls))
        |> Enum.map(fn scan ->
          ~s(ravner_lighthouse_cls{domain="#{escape_label(scan.domain)}"} #{scan.cls})
        end)

      [
        format_metric_block(
          "ravner_lighthouse_score",
          "gauge",
          "Latest completed Lighthouse category score (0-100) per domain",
          score_lines
        ),
        format_metric_block(
          "ravner_lighthouse_web_vital_ms",
          "gauge",
          "Latest completed Lighthouse timing metric in milliseconds per domain",
          vital_lines
        ),
        format_metric_block(
          "ravner_lighthouse_cls",
          "gauge",
          "Latest completed Lighthouse Cumulative Layout Shift (CLS) per domain",
          cls_lines
        )
      ]
      |> join_metric_blocks()
    rescue
      _ -> ""
    end
  end

  defp format_a11y_metrics do
    try do
      import Ecto.Query
      alias Ravner.A11y.A11yScan
      alias Ravner.Domains.Domain

      latest_scans =
        Ravner.Repo.all(
          from(a in A11yScan,
            join: d in Domain,
            on: d.id == a.domain_id,
            where: a.status == "completed",
            distinct: a.domain_id,
            order_by: [asc: a.domain_id, desc: a.completed_at, desc: a.id],
            select: %{
              domain: d.name,
              standard: a.standard,
              violations_count: a.violations_count,
              warnings_count: a.warnings_count
            }
          )
        )

      violation_lines =
        latest_scans
        |> Enum.reject(&is_nil(&1.violations_count))
        |> Enum.map(fn scan ->
          standard = scan.standard || "WCAG2AA"

          ~s(ravner_a11y_violations{domain="#{escape_label(scan.domain)}",standard="#{escape_label(standard)}"} #{scan.violations_count})
        end)

      warning_lines =
        latest_scans
        |> Enum.reject(&is_nil(&1.warnings_count))
        |> Enum.map(fn scan ->
          standard = scan.standard || "WCAG2AA"

          ~s(ravner_a11y_warnings{domain="#{escape_label(scan.domain)}",standard="#{escape_label(standard)}"} #{scan.warnings_count})
        end)

      [
        format_metric_block(
          "ravner_a11y_violations",
          "gauge",
          "Accessibility violations count from latest completed WCAG scan per domain",
          violation_lines
        ),
        format_metric_block(
          "ravner_a11y_warnings",
          "gauge",
          "Accessibility warnings count from latest completed WCAG scan per domain",
          warning_lines
        )
      ]
      |> join_metric_blocks()
    rescue
      _ -> ""
    end
  end

  defp format_repository_security_metrics do
    try do
      import Ecto.Query
      alias Ravner.Domains.Domain
      alias Ravner.Inventory.Project
      alias Ravner.Inventory.ProjectRepository

      repos =
        Ravner.Repo.all(
          from(r in ProjectRepository,
            left_join: p in Project,
            on: p.id == r.project_id,
            left_join: d in Domain,
            on: d.id == r.domain_id,
            select: %{
              project: p.name,
              domain: d.name,
              repository: coalesce(r.external_id, r.url),
              critical: r.critical_vuln_count,
              high: r.high_vuln_count,
              medium: r.medium_vuln_count,
              low: r.low_vuln_count,
              secrets: r.secrets_count
            }
          )
        )

      severities = [
        {:critical, "critical"},
        {:high, "high"},
        {:medium, "medium"},
        {:low, "low"}
      ]

      vuln_lines =
        for repo <- repos,
            {field, severity} <- severities do
          count = Map.get(repo, field) || 0
          project = repo.project || "unassigned"
          domain = repo.domain || "unassigned"

          ~s(ravner_repository_vulnerabilities{project="#{escape_label(project)}",repository="#{escape_label(repo.repository)}",domain="#{escape_label(domain)}",severity="#{severity}"} #{count})
        end

      secret_lines =
        Enum.map(repos, fn repo ->
          count = repo.secrets || 0
          project = repo.project || "unassigned"
          domain = repo.domain || "unassigned"

          ~s(ravner_repository_secrets{project="#{escape_label(project)}",repository="#{escape_label(repo.repository)}",domain="#{escape_label(domain)}"} #{count})
        end)

      [
        format_metric_block(
          "ravner_repository_vulnerabilities",
          "gauge",
          "Open repository dependency vulnerabilities (CVEs) by severity",
          vuln_lines
        ),
        format_metric_block(
          "ravner_repository_secrets",
          "gauge",
          "Detected leaked secrets count per repository",
          secret_lines
        )
      ]
      |> join_metric_blocks()
    rescue
      _ -> ""
    end
  end

  defp format_metric_block(_name, _type, _help, []), do: ""

  defp format_metric_block(name, type, help, lines) do
    """
    # HELP #{name} #{help}
    # TYPE #{name} #{type}
    #{Enum.join(lines, "\n")}
    """
    |> String.trim()
  end

  defp join_metric_blocks(blocks) do
    blocks
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp format_vm_metrics do
    memory = :erlang.memory()
    total_bytes = Keyword.get(memory, :total, 0)
    proc_bytes = Keyword.get(memory, :processes, 0)
    atom_bytes = Keyword.get(memory, :atom, 0)
    bin_bytes = Keyword.get(memory, :binary, 0)
    ets_bytes = Keyword.get(memory, :ets, 0)

    process_count = :erlang.system_info(:process_count)
    run_queue = :erlang.statistics(:run_queue)

    """
    # HELP vm_memory_bytes Memory allocated by Erlang BEAM runtime
    # TYPE vm_memory_bytes gauge
    vm_memory_bytes{kind="total"} #{total_bytes}
    vm_memory_bytes{kind="processes"} #{proc_bytes}
    vm_memory_bytes{kind="atom"} #{atom_bytes}
    vm_memory_bytes{kind="binary"} #{bin_bytes}
    vm_memory_bytes{kind="ets"} #{ets_bytes}

    # HELP vm_process_count Total active BEAM processes
    # TYPE vm_process_count gauge
    vm_process_count #{process_count}

    # HELP vm_run_queue_length Total BEAM scheduler run queue length
    # TYPE vm_run_queue_length gauge
    vm_run_queue_length #{run_queue}
    """
    |> String.trim()
  end

  # ── Label Escaping Helper ──────────────────────────────────────────────────

  defp escape_label(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp escape_label(other), do: to_string(other)
end
