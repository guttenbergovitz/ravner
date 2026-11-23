defmodule RavnerWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("ravner.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("ravner.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("ravner.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("ravner.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("ravner.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Synthetic Domain & Vulnerability Metrics (OpenTelemetry SemConv)
      summary("ravner.synthetic.http.stop.duration_ms",
        unit: :millisecond,
        description: "Synthetic HTTP heartbeat probe latency"
      ),
      counter("ravner.synthetic.http.stop.count",
        description: "Total synthetic HTTP probes executed"
      ),
      summary("ravner.synthetic.sca.stop.duration_ms",
        unit: :millisecond,
        description: "Software Composition Analysis (SCA) scan duration"
      ),
      sum("ravner.synthetic.sca.stop.vulnerability_count",
        description: "Total vulnerabilities discovered across repositories"
      ),
      summary("ravner.synthetic.tls.stop.handshake_ms",
        unit: :millisecond,
        description: "TLS handshake duration"
      ),
      summary("ravner.synthetic.uptime.status.response_time_ms",
        unit: :millisecond,
        description: "Uptime probe response time"
      ),
      last_value("ravner.synthetic.uptime.status.status",
        description: "Current domain availability status (1 for up, 0 for down)"
      ),
      counter("ravner.synthetic.incident.opened.count",
        description: "Incidents opened"
      ),
      counter("ravner.synthetic.incident.resolved.count",
        description: "Incidents resolved"
      ),
      summary("ravner.synthetic.incident.resolved.duration_seconds",
        unit: :second,
        description: "Incident downtime duration until resolution (MTTR)"
      ),
      summary("ravner.synthetic.web_vitals.stop.lcp_ms",
        unit: :millisecond,
        description: "Largest Contentful Paint (LCP)"
      ),
      summary("ravner.synthetic.web_vitals.stop.performance_score",
        description: "Google Lighthouse Performance Score (0-100)"
      ),
      sum("ravner.synthetic.a11y.stop.violations_count",
        description: "Total WCAG accessibility violations"
      ),
      summary("ravner.synthetic.dns.stop.duration_ms",
        unit: :millisecond,
        description: "DNS resolution latency"
      ),
      sum("ravner.synthetic.security_headers.stop.findings_count",
        description: "Total security headers posture findings"
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {RavnerWeb, :count_users, []}
    ]
  end
end
