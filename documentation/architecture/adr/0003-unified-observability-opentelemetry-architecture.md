# ADR 0003: Unified Observability & OpenTelemetry Semantic Telemetry Architecture

**Status:** Proposed  
**Date:** 2026-09-25  
**Deciders:** Core Engineering Team  
**Consulted:** Ravner Architecture Team  

---

## 1. Context and Problem Statement

Ravner operates as an Attack Surface Management (ASM), external domain observability, and asset governance platform. In this capacity, it collects continuous operational and synthetic health metrics across monitored domains, web applications, and source code repositories:

* **Synthetic Heartbeat & Uptime**: HTTP response latency, availability status, connection timeouts, transport errors.
* **TLS / SSL Telemetry**: Handshake duration, certificate expiration dates, protocol versions (TLS 1.2 vs. deprecated 1.0/1.1), cipher suites.
* **DNS & Infrastructure Metrics**: Resolution times, nameserver health, record drift.
* **Security & Vulnerability Findings**: Software Composition Analysis (SCA) CVE counts from Bitbucket/GitHub/GitLab, Google OSV severity scores (CVSS), high-risk probe detections (.env leaks, exposed debug panels).
* **Client Performance Audits**: Google Lighthouse metrics (Largest Contentful Paint, Cumulative Layout Shift, Total Blocking Time) and accessibility compliance scores.

### The Architectural Problem: Data Silos and Metric Chaos

Despite the high analytical value of this data, its collection and lifecycle currently suffer from three fundamental architectural deficiencies:

1. **The Dual-World Confusion (Whitebox vs. Blackbox)**:
   Ravner mixes two entirely distinct observability domains without a formal conceptual boundary:
   * **Whitebox Telemetry (APM - How Ravner Runs)**: Internal health of the Phoenix server, Ecto database pools, BEAM VM memory, Oban job queues. This currently uses standard `:telemetry` in `RavnerWeb.Telemetry`.
   * **Blackbox / Synthetic Telemetry (What Ravner Measures)**: External measurements of customer domains and repositories. Currently, this bypasses the telemetry subsystem entirely and writes directly into relational PostgreSQL tables (`heartbeats`, `domain_metadata`, `security_scans`, `project_repository_vulnerabilities`).

2. **Ad-Hoc Schemas vs. OpenTelemetry Semantic Conventions (SemConv)**:
   Data captured by workers is saved using arbitrary, non-standardized column names and raw strings (e.g. error reasons stored as `"http_500"`, `"timeout"`, `"nxdomain"`). The Cloud Native Computing Foundation (CNCF) provides mature **OpenTelemetry Semantic Conventions** for network, HTTP, TLS, and vulnerability telemetry (e.g. `http.response.status_code`, `server.address`, `tls.protocol.version`, `vulnerability.id`, `vulnerability.severity`). Failing to align with these conventions prevents interoperability.

3. **Data Silo (No External Export)**:
   Ravner functions as an isolated island. Enterprise security and operations teams that operate enterprise-wide SIEM/Observability stacks (Prometheus, Grafana Mimir/Loki/Tempo, Datadog, Dynatrace, SigNoz, AWS CloudWatch) cannot stream or scrape Ravner's continuous synthetic findings via OpenTelemetry Protocol (OTLP) or Prometheus scrape endpoints (`/metrics`).

We require a formal, unified observability architecture that structures all synthetic and internal metrics according to OpenTelemetry standards while preserving Ravner's core architectural tenets (BEAM-first performance, "Stop Line" rule, zero bloat).

---

## 2. Decision Drivers

* **Open Standards First (CNCF OpenTelemetry)**: Standardize metric names, attributes, and events according to OpenTelemetry Semantic Conventions (SemConv).
* **Decoupled Architecture (The BEAM Telemetry Spine)**: Decouple data gathering from storage. Scanners must emit structured `:telemetry` events into the BEAM bus; persistence in PostgreSQL, LiveDashboard rendering, and external exports become pure decoupled consumers.
* **Zero Overhead on Hot Paths**: Emitting `:telemetry` events in BEAM takes less than 1 microsecond. High-concurrency Oban workers must not incur HTTP/database lock contention for observability.
* **Enterprise Interoperability**: Support out-of-the-box Prometheus scraping (`/metrics`) and optional OpenTelemetry Protocol (OTLP over HTTP/Protobuf).
* **Respect the "Stop Line" Rule**: Runtime metrics and high-volume synthetic telemetry MUST remain on pure Ecto/BEAM/`:telemetry`. Ash Framework remains reserved strictly for governance, ownership, and administrative authorization.

---

## 3. Considered Options

* **Option 1: Status Quo (Direct Relational Storage Only)**  
  Keep storing metrics solely as PostgreSQL rows. Write custom API controllers when external tools need data.  
  *Critique*: Reinforces data silos, scales poorly with high-frequency heartbeats, and offers no standardization.

* **Option 2: Pure Prometheus Model (`prom_ex` / custom metrics)**  
  Instrument scanners specifically for Prometheus counters, gauges, and histograms.  
  *Critique*: Solves metric scraping for Prometheus, but ignores distributed tracing (spans for multi-phase security scans), logs correlation, and locks the platform into Prometheus-specific conventions instead of vendor-neutral OpenTelemetry.

* **Option 3: Unified BEAM-First Observability: `:telemetry` Event Spine + OTel Semantic Conventions + Pluggable Exporters (Selected)**  
  Adopt a 3-layer architecture:
  1. **Event Spine**: All scanners emit standardized BEAM `:telemetry` events with microsecond overhead.
  2. **OTel Semantic Taxonomy**: Event payloads adhere strictly to OpenTelemetry Semantic Conventions.
  3. **Pluggable Consumers**:
     - *Relational Consumer*: Existing Ecto/Oban persistence for UI display.
     - *Local LiveDashboard*: Real-time operational graphs in Phoenix LiveDashboard.
     - *Prometheus / OTLP Exporters*: Standard `/metrics` endpoint and push-based OTLP exporter for enterprise stacks.

---

## 4. Decision Outcome

**Chosen Option: Option 3 — Unified BEAM-First Observability Architecture.**

### High-Level Architecture Diagram

```
┌───────────────────────────────────────────────────────────────────────────────────┐
│                           SYNTHETIC PRODUCERS (Runtime)                           │
│  HeartbeatWorker       RepoScanner        NativeScanner      Lighthouse / A11y    │
└─────────┬───────────────────┬───────────────────┬───────────────────┬─────────────┘
          │                   │                   │                   │
          ▼                   ▼                   ▼                   ▼
┌───────────────────────────────────────────────────────────────────────────────────┐
│                       BEAM `:telemetry` EVENT SPINE                               │
│  [:ravner, :synthetic, :http, :stop]         [:ravner, :synthetic, :sca, :stop]  │
│  [:ravner, :synthetic, :tls, :stop]          [:ravner, :scanner, :probe, :stop]  │
│                                                                                   │
│  Payloads adhere to OpenTelemetry Semantic Conventions:                           │
│  Measurements: %{duration_ms: 142, response_time_ms: 135, vuln_count: 3}          │
│  Metadata:     %{server.address: "example.com", http.response.status_code: 200,   │
│                  vulnerability.severity: "HIGH", ravner.project_id: 42}           │
└────────────────────────────────────────┬──────────────────────────────────────────┘
                                         │ (Subscribers)
          ┌──────────────────────────────┼──────────────────────────────┐
          ▼                              ▼                              ▼
┌──────────────────┐           ┌───────────────────┐          ┌───────────────────┐
│ RELATIONAL DB    │           │ PHOENIX APM       │          │ EXPORTERS (OTel)  │
│ Consumer (Ecto)  │           │ LiveDashboard     │          │ Prometheus / OTLP │
├──────────────────┤           ├───────────────────┤          ├───────────────────┤
│ • heartbeats     │           │ • Real-time p95   │          │ • /metrics        │
│ • domain_metadata│           │ • Scans / sec     │          │ • OTLP Exporter   │
│ • scan_findings  │           │ • Error rates     │          │ • Grafana / SIEM  │
└──────────────────┘           └───────────────────┘          └───────────────────┘
```

---

## 5. OpenTelemetry Semantic Taxonomy for Ravner

All events emitted by Ravner components must conform to the following taxonomy:

### 5.1 Synthetic HTTP & Heartbeat Probes
* **Event Name**: `[:ravner, :synthetic, :http, :stop]` (and `:exception`)
* **Measurements**:
  * `duration_ms` (integer): Total round-trip time in milliseconds.
  * `response_time_ms` (integer | nil): Time to first byte if successful.
* **Metadata (OTel SemConv)**:
  * `server.address` (string): Target domain (e.g., `"app.example.com"`).
  * `url.full` (string): Full URL probed (`"https://app.example.com/health"`).
  * `http.request.method` (string): `"HEAD"`, `"GET"`.
  * `http.response.status_code` (integer | nil): `200`, `404`, `502`.
  * `network.transport` (string): `"tcp"`.
  * `error.type` (string | nil): `"timeout"`, `"econnrefused"`, `"nxdomain"`, `"ssl_error"`.
  * `ravner.domain_id` (integer): Internal ID for relational scoping.
  * `ravner.organization_id` (integer | nil): Scoped organization ID.

### 5.2 Synthetic TLS & Certificate Audits
* **Event Name**: `[:ravner, :synthetic, :tls, :stop]`
* **Measurements**:
  * `tls.certificate.days_until_expiry` (integer): Remaining validity in days.
  * `tls.handshake.duration_ms` (integer): Time taken to complete handshake.
* **Metadata (OTel SemConv)**:
  * `server.address` (string): Target host.
  * `tls.protocol.version` (string): `"TLSv1.3"`, `"TLSv1.2"`, `"TLSv1.0"`.
  * `tls.cipher` (string): Negotiated cipher suite.
  * `tls.certificate.issuer` (string): Certificate authority (e.g., `"Let's Encrypt"`).
  * `tls.status` (atom): `:valid`, `:expired`, `:untrusted`, `:deprecated_protocol`.

### 5.3 Software Composition Analysis (SCA) & Repository Scans
* **Event Name**: `[:ravner, :synthetic, :sca, :stop]`
* **Measurements**:
  * `duration_ms` (integer): Time spent analyzing manifest and querying OSV.dev.
  * `vulnerability.count` (integer): Total detected vulnerabilities.
  * `vulnerability.critical_count` (integer): Severity `CRITICAL`.
  * `vulnerability.high_count` (integer): Severity `HIGH`.
* **Metadata (OTel SemConv)**:
  * `vcs.provider` (string): `"bitbucket"`, `"github"`, `"gitlab"`.
  * `vcs.repository.name` (string): Repository slug.
  * `vcs.repository.url` (string): Full repository URL.
  * `ravner.project_id` (integer): Associated project ID.
  * `ravner.domain_id` (integer | nil): Associated domain ID.

---

## 6. Implementation Stages & Consequences

The transition will proceed across three planned phases:

1. **Phase 1: Foundation (BEAM Telemetry Spine)**:
   Create `Ravner.Telemetry.Synthetic` defining event contracts. Instrument `HeartbeatWorker`, `RepoScanner`, and `NativeScanner`.
2. **Phase 2: LiveDashboard & Semantic Real-time View**:
   Configure `RavnerWeb.Telemetry` with telemetry metrics (Histograms, Summaries) so that operators can monitor real-time scanner throughput, p95 probe latency, and error breakdown in `Phoenix.LiveDashboard`.
3. **Phase 3: Standard Enterprise Exporters**:
   Implement a `/metrics` endpoint compatible with Prometheus/OpenMetrics and support the standard OpenTelemetry collector protocol (OTLP).

### Consequences
* **Positive**:
  * Eliminates metric chaos by adopting standard CNCF naming conventions.
  * Decouples data emission from PostgreSQL writes, improving throughput.
  * Unlocks seamless integration with Grafana, Prometheus, Datadog, and enterprise SIEM tools.
  * Provides instant visibility into scan performance without custom database queries.
* **Negative**:
  * Requires maintaining a clear catalogue of `:telemetry` events and ensuring new scanners adhere to the schema.
