# Observability & OpenTelemetry Implementation Plan

**Author:** Ravner Architecture Team  
**Reference ADR:** [ADR 0003: Unified Observability & OpenTelemetry Semantic Telemetry Architecture](adr/0003-unified-observability-opentelemetry-architecture.md)  
**Status:** Ready for Implementation  
**Target Version:** Ravner v0.10.0+  

---

## 1. Overview & Objective

This document outlines the step-by-step technical implementation plan for transforming Ravner's metric collection from an ad-hoc relational database silo into a standard, unified **OpenTelemetry (OTel)** and **BEAM Telemetry** architecture.

### Key Goals
1. **Decouple Synthetic Probing from Storage**: Allow workers (`HeartbeatWorker`, `RepoScanner`, `NativeScanner`, `LighthouseScanWorker`) to emit microsecond-fast `:telemetry` events.
2. **Align with OpenTelemetry Semantic Conventions (SemConv)**: Replace raw, inconsistent strings and boolean flags with standardized telemetry attributes (`http.response.status_code`, `server.address`, `vulnerability.id`, `tls.protocol.version`).
3. **Real-Time Visibility in Phoenix LiveDashboard**: Enable developers and operators to monitor synthetic throughput, p50/p95 latency, and error breakdown in real time without querying PostgreSQL.
4. **Prometheus / Grafana Compatibility**: Provide an OpenMetrics `/metrics` endpoint for enterprise scraping.
5. **Zero Performance Overhead**: Respect the BEAM-first design and the **"Stop Line"** rule (pure Ecto/`:telemetry` for runtime, Ash Framework for governance).

---

## 2. Technical Architecture & Component Design

```
┌────────────────────────────────────────────────────────────────────────────────┐
│                             PRODUCERS (Runtime)                                │
│                                                                                │
│   HeartbeatWorker          RepoScanner          NativeScanner      Lighthouse  │
│   (HTTP & SSL Ping)      (VCS Lockfiles)      (Curated Probes)    (Web Vitals) │
└───────────┬──────────────────────┬──────────────────────┬───────────────┬──────┘
            │                      │                      │               │
            ▼                      ▼                      ▼               ▼
┌────────────────────────────────────────────────────────────────────────────────┐
│                     Ravner.Telemetry.Synthetic (Facade)                        │
│                                                                                │
│  Wraps :telemetry.execute/3 with strict specs and OTel Semantic Conventions    │
│  • emit_http_probe(measurements, metadata)                                     │
│  • emit_tls_probe(measurements, metadata)                                      │
│  • emit_sca_scan(measurements, metadata)                                       │
│  • emit_native_probe(measurements, metadata)                                   │
└──────────────────────────────────────┬─────────────────────────────────────────┘
                                       │
                    ┌──────────────────┴──────────────────┐
                    ▼                                     ▼
┌───────────────────────────────────────┐  ┌─────────────────────────────────────┐
│             SUBSCRIBER 1              │  │            SUBSCRIBER 2             │
│        (Phoenix LiveDashboard)        │  │       (Prometheus / OpenMetrics)    │
├───────────────────────────────────────┤  ├─────────────────────────────────────┤
│ Handled via RavnerWeb.Telemetry       │  │ Handled via /metrics endpoint       │
│ • summary("ravner.synthetic.http...") │  │ • ravner_synthetic_http_duration_ms │
│ • counter("ravner.synthetic.sca...")  │  │ • ravner_synthetic_cve_count_total  │
│ Live graphs in Phoenix Dashboard      │  │ Scraped by Prometheus & Grafana     │
└───────────────────────────────────────┘  └─────────────────────────────────────┘
```

---

## 3. Phase-by-Phase Execution Plan

### Phase 1: The Core Telemetry Event Spine & Contract (Foundation)

**Objective**: Create the central telemetry facade module and instrument the runtime workers.

#### Task 1.1: Create `Ravner.Telemetry.Synthetic`
Create a centralized module with strict `@spec` definitions ensuring all emitted events adhere to OpenTelemetry Semantic Conventions:
* `emit_http_probe/2`:
  * Event: `[:ravner, :synthetic, :http, :stop]`
  * Measurements: `%{duration_ms: integer(), response_time_ms: integer() | nil}`
  * Metadata:
    * `"server.address"`: Target host (e.g., `"example.com"`)
    * `"url.full"`: Full probed URL
    * `"http.request.method"`: `"HEAD"` or `"GET"`
    * `"http.response.status_code"`: integer status code or `nil`
    * `"error.type"`: standardized string (`"timeout"`, `"econnrefused"`, `"nxdomain"`, `"ssl_error"`)
    * `"ravner.domain_id"`: internal domain ID
* `emit_sca_scan/2`:
  * Event: `[:ravner, :synthetic, :sca, :stop]`
  * Measurements: `%{duration_ms: integer(), vulnerability_count: integer(), critical_count: integer(), high_count: integer()}`
  * Metadata:
    * `"vcs.provider"`: `"bitbucket"`, `"github"`, `"gitlab"`
    * `"vcs.repository.name"`: repository slug
    * `"ravner.project_id"`: project ID
    * `"ravner.domain_id"`: domain ID (optional)
* `emit_tls_probe/2`:
  * Event: `[:ravner, :synthetic, :tls, :stop]`
  * Measurements: `%{days_until_expiry: integer(), handshake_ms: integer()}`
  * Metadata:
    * `"server.address"`: host
    * `"tls.protocol.version"`: `"TLSv1.3"`, `"TLSv1.2"`, etc.
    * `"tls.status"`: `:valid`, `:expired`, `:untrusted`

#### Task 1.2: Instrument `Ravner.Workers.HeartbeatWorker`
* Wrap the check execution in `System.monotonic_time(:millisecond)`.
* Call `Ravner.Telemetry.Synthetic.emit_http_probe/2` before or alongside `Uptime.record_check/2`.
* Ensure zero database lock overhead.

#### Task 1.3: Instrument `Ravner.Scans.RepoScanner`
* Measure elapsed scan time and detected vulnerability counts by severity.
* Call `Ravner.Telemetry.Synthetic.emit_sca_scan/2` upon scan completion.

---

### Phase 2: LiveDashboard Integration & Real-Time Operational View

**Objective**: Make synthetic metrics immediately visible and actionable inside the running application.

#### Task 2.1: Register Metrics in `RavnerWeb.Telemetry`
Expand `RavnerWeb.Telemetry.metrics/0` to declare Telemetry.Metrics definitions:
```elixir
# Synthetic HTTP Metrics
summary("ravner.synthetic.http.stop.duration_ms",
  unit: :millisecond,
  tags: [:"server.address", :"http.response.status_code", :"error.type"],
  description: "Synthetic HTTP probe latency"
),
counter("ravner.synthetic.http.stop.count",
  tags: [:"http.response.status_code", :"error.type"],
  description: "Total synthetic HTTP probes executed"
),

# Synthetic SCA Vulnerability Metrics
summary("ravner.synthetic.sca.stop.duration_ms",
  unit: :millisecond,
  tags: [:"vcs.provider"],
  description: "SCA repo scan execution time"
),
sum("ravner.synthetic.sca.stop.vulnerability_count",
  tags: [:"vcs.provider"],
  description: "Total vulnerabilities discovered across repositories"
)
```

#### Task 2.2: Add "Synthetic Observability" to LiveDashboard
In `lib/ravner_web/router.ex`, configure `live_dashboard` to render a dedicated page for synthetic metrics alongside Phoenix and VM metrics.

---

### Phase 3: OpenMetrics & Prometheus Exporter (`/metrics`)

**Objective**: Allow external Prometheus/Grafana infrastructure to scrape Ravner metrics.

#### Task 3.1: Expose `/metrics` Endpoint
* Implement a lightweight Plug/Controller `RavnerWeb.MetricsController` that aggregates `Telemetry.Metrics` into Prometheus text format:
  ```
  # HELP ravner_synthetic_http_duration_ms Synthetic HTTP probe latency
  # TYPE ravner_synthetic_http_duration_ms summary
  ravner_synthetic_http_duration_ms{quantile="0.5",server_address="example.com"} 142
  ravner_synthetic_http_duration_ms{quantile="0.95",server_address="example.com"} 420
  
  # HELP ravner_synthetic_vulnerabilities_total Total vulnerabilities tracked
  # TYPE ravner_synthetic_vulnerabilities_total gauge
  ravner_synthetic_vulnerabilities_total{severity="CRITICAL",provider="bitbucket"} 4
  ```
* Secure the endpoint behind bearer token authentication (`BEARER_METRICS_TOKEN`) or restrict access to internal networks / admin sessions.

---

### Phase 4: Distributed Tracing & OTLP Export (Future Phase)

**Objective**: Distributed context propagation for complex multi-step scans.

* **Trace Context Propagation**:
  When a user triggers a "Deep Security Scan" for a domain, create an OpenTelemetry `Trace` containing:
  - Root Span: `domain_security_scan` (target: `example.com`)
    - Child Span 1: `dns_resolution`
    - Child Span 2: `tls_handshake_audit`
    - Child Span 3: `http_probe_fingerprint`
    - Child Span 4: `curated_probes` (with sub-spans for sensitive paths)
    - Child Span 5: `cve_correlation_osv`
* **OTLP gRPC/HTTP Exporter**:
  Optional integration with `:opentelemetry_exporter` pushing spans to Grafana Tempo, SigNoz, or Jaeger.

---

## 4. Testing & Verification Strategy

1. **ExUnit Telemetry Test Harness**:
   Use `:telemetry.attach/4` in unit tests to assert that workers emit the expected events with valid measurements and metadata:
   ```elixir
   test "HeartbeatWorker emits [:ravner, :synthetic, :http, :stop] with OTel metadata" do
     ref = make_ref()
     parent = self()

     :telemetry.attach(
       "test-heartbeat-#{inspect(ref)}",
       [:ravner, :synthetic, :http, :stop],
       fn _event, measurements, metadata, _config ->
         send(parent, {:telemetry_event, measurements, metadata})
       end,
       nil
     )

     # Execute worker
     HeartbeatWorker.perform(%Oban.Job{args: %{"domain_id" => domain.id}})

     assert_receive {:telemetry_event, measurements, metadata}
     assert measurements.duration_ms > 0
     assert metadata["server.address"] == domain.name
     assert is_integer(metadata["http.response.status_code"])
   end
   ```
2. **Performance Regression Check**:
   Benchmark worker throughput before and after `:telemetry` emission to verify zero performance degradation (< 1% delta).
3. **Format & Compilation**:
   Maintain `mix precommit` passing cleanly with zero warnings under `--warnings-as-errors`.

---

## 5. Rollout Checklist

- [x] Review and merge [ADR 0003](adr/0003-unified-observability-opentelemetry-architecture.md).
- [x] Implement `Ravner.Telemetry.Synthetic` contract module.
- [x] Instrument `HeartbeatWorker`.
- [x] Instrument `RepoScanner`.
- [x] Instrument `Ravner.Uptime`, `Lighthouse`, `A11y`, `Dns`, `TlsHeaderAudit`.
- [x] Add metric declarations in `RavnerWeb.Telemetry`.
- [x] LiveView inspector `/admin/telemetry` with live PubSub streaming and JSON drawer.
- [x] Add ExUnit tests for telemetry emission (23 tests).
- [x] (Phase 3) Expose authenticated `/metrics` endpoint for Prometheus with constant-time token security.
