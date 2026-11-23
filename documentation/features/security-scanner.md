# Security & Threat Intelligence Scanner

**Status:** Implemented (BEAM-First Architecture)  
**Context:** `Ravner.SecurityScans`, `Ravner.Scans.SecurityRunner`

---

## 1. Overview

Ravner provides an enterprise-grade, BEAM-first attack surface discovery and security posture evaluation engine. It eliminates the resource bloat and stability risks of heavy external vulnerability scanners by running lightweight, in-process network audits in pure Elixir/Erlang while isolating deep scans behind explicit administrative boundaries.

The security subsystem is built around two complementary intelligence streams:
1. **Infrastructure & Application Posture (Vulnerability Scanning)**: Native HTTP probing, targeted secret exposure checks, real-time CVE correlation via Google OSV.dev, and in-process TLS/header security audits.
2. **Dark Web Infostealer Intelligence (Breach Detection)**: Asynchronous lookups against threat intelligence feeds (Hudson Rock, BreachDirectory) to identify compromised corporate credentials and corporate credentials leaked in stealer logs.

---

## 2. Architecture: BEAM-First Hybrid Engine

Ravner adheres to the **Stop Line** rule: all scan execution, network I/O, and finding persistence occur strictly in **pure Ecto and Oban**, completely bypassing Ash governance overhead.

```
                  ┌────────────────────────────────────────────────────────┐
                  │              Target Domain (URL / Host)                │
                  └──────────────────────────┬─────────────────────────────┘
                                             │
                   ┌─────────────────────────┴─────────────────────────┐
                   │                                                   │
                   ▼                                                   ▼
      Phase 1: HTTP Probe & Fingerprint               Phase 2: Curated Probes
      • Status, Server, Redirects (Req)               • 35 targeted sensitive paths
      • Technology identification                     • .env, .git/HEAD, backups
      • Exact version extraction                      • Spring/Laravel/Swagger debuggers
                   │                                                   │
                   ▼                                                   ▼
      Phase 3: CVE Lookup (OSV.dev)                   Phase 4: TLS & Headers Audit
      • Query Google OSV.dev batch API                • Security headers (HSTS, CSP, XFO)
      • Match (ecosystem, package, version)           • In-process :ssl handshake test
      • Generate ScanFindings                         • Deprecated TLS 1.0/1.1 detection
                   │                                                   │
                   └─────────────────────────┬─────────────────────────┘
                                             │
                                             ▼
                                  Consolidated Findings
                              (Persisted via Pure Ecto)
```

### 2.1 The Native `:light` Pipeline (Primary & Default)

Managed by `Ravner.Scans.SecurityRunner.run_security_scan/4` (or `run_security_scan_sync/3` for batch jobs), the `:light` pipeline executes within a supervised `Task` across four deterministic phases:

1. **Phase 1: HTTP Probe & Fingerprinting (`Ravner.Scans.Http`, `TechFingerprint`)**:
   - Inspects status codes, canonical URL redirects, and server headers using `Req`.
   - Fingerprints CMS, web server, and application runtime versions using local Wappalyzer signatures.
2. **Phase 2: Curated High-Impact Probes (`Ravner.Scans.CuratedProbes`)**:
   - Executes 35 high-confidence probes against known sensitive files, misconfigured administrative dashboards, and leaked secrets:
     - **Secrets & Repos**: `/.env`, `/.git/HEAD`, `/wp-config.php.bak`, `/.aws/credentials`, `/docker-compose.yml`.
     - **Framework Exposures**: `/actuator/env`, `/actuator/heapdump`, `/_ignition/health-checks`, `/phpinfo.php`, `/swagger-ui/index.html`.
   - Bounded by strict resource safeguards:
     - Hard **4 KB response body limit** (streaming download terminates immediately once exceeded).
     - **2-second HTTP timeout** per probe.
     - **Concurrency cap of 5** per target.
     - Anti-soft-404 heuristics (verifies response payload signatures, not just 200 OK headers).
3. **Phase 3: Real-Time CVE Intelligence (`Ravner.Scans.CveLookup`, `CveCache`)**:
   - Correlates detected package ecosystems and exact versions with Google OSV.dev in real time.
   - Dual-tier caching: **L1 ETS** in-memory table (microsecond access) backed by **L2 PostgreSQL** cache (`cve_cache`).
4. **Phase 4: TLS & Header Security Audit (`Ravner.Scans.TlsHeaderAudit`)**:
   - **In-process SSL Handshake**: Attempts connection via `:ssl` forcing `:tlsv1` and `:tlsv1.1` to detect deprecated cipher suites and obsolete protocol versions.
   - **HTTP Header Compliance**: Audits `Strict-Transport-Security` (HSTS), `Content-Security-Policy` (CSP), and `X-Frame-Options` (clickjacking protection).

### 2.2 The On-Demand `:heavy` Pipeline (Secondary)

For deep compliance audits, administrators can trigger the heavy pipeline:
- Spawns external `naabu` for comprehensive port discovery and `nuclei` for vulnerability checks.
- Executed under process isolation via `Ravner.SystemCommand.run_with_timeout/4` with process group isolation (`PGID`) and aggressive zombie process termination.

### 2.3 Dark Web Breach Intelligence (`Ravner.Scans.BreachLookup`)

Operates as a distinct scanner category (`tool: "breach_lookup"`):
- Queries external threat intelligence APIs (Hudson Rock Cavalier, BreachDirectory).
- Correlates domains with stolen employee passwords, corporate email leaks, and infostealer malware dumps.
- **Independent Scans**: Breach scans and infrastructure vulnerability scans are maintained independently in `Ravner.SecurityScans`, ensuring running a breach lookup never clears or overwrites technical vulnerability findings.

---

## 3. Data Model & Retention

| Table | Module | Purpose |
|---|---|---|
| `security_scans` | `Ravner.SecurityScans.SecurityScan` | Root record capturing scan type, status, duration, progress, target, and summary. |
| `scan_findings` | `Ravner.SecurityScans.ScanFinding` | Individual vulnerability or threat records with severity (`critical`, `high`, `medium`, `low`, `info`), target, title, and metadata JSON. |

### Smart Pruning (`Ravner.SecurityScans.prune_old_scans/1`)
To prevent unbounded table growth while preserving historical auditability:
- Retains up to **5 most recent completed vulnerability scans** (`security_scan`, `light_scan`, `naabu`, `nuclei`).
- Retains up to **5 most recent completed dark web breach scans** (`breach_lookup`).
- Preserves all currently active/running scans.
- Bulk purges historical scans beyond this window along with their associated `scan_findings`.

---

## 4. User Interface & Operator Workflows

### 4.1 Domain Security Posture Component (Modal / Inline)
Located in `RavnerWeb.DomainLive.SecurityPostureComponent`:
- Displays independent badges for technical vulnerability severity (`Critical`, `High`, `Medium`, `Low`) and dark web employee breach count.
- Provides one-click action buttons to trigger native security scans or dark web lookups.
- Features a clean CTA link: **`View Security Report`** navigating to the full report.

### 4.2 Dedicated Security & Threat Report (`/domains/:id/security`)
Located in `RavnerWeb.DomainLive.SecurityReport`:
- **Summary Metrics**: High-level metric cards showing Total Findings, Critical Flaws, Exposed Secrets, and Scanned Ports.
- **Filterable Category Tabs**:
  - **All Findings**: Consolidated list sorted by severity.
  - **CVE Vulnerabilities**: Software flaws matched via OSV.dev.
  - **Sensitive Exposures**: Curated probe hits (`.env`, `.git`, debug panels).
  - **TLS & Headers**: Missing security headers and deprecated TLS 1.0/1.1 protocols.
  - **Open Ports**: Discovered network ports.
  - **Dark Web Breaches**: Infostealer breach telemetry.
  - **Scan History**: Historical execution log.
- **Interactive Finding Modal**: Clicking any finding reveals full curl reproduction commands, raw evidence, CWE references, and remediation guidance.

### 4.3 Bulk Security Scanning (`/domains`)
Located in `RavnerWeb.DomainLive.Index`:
- Operators can enter **Selection Mode**, choose target domains (with optional subdomain expansion), and select **`Run Security Scan`** from the bulk operations menu.
- Executes parallel scans via `Task.async_stream` throttled to `Scans.scan_max_concurrency/0`.
- Displays real-time progress indicators in the domain table rows and automatically updates table state upon completion.

### 4.4 Portfolio Security Command Center (`/dashboard`)
Located in `RavnerWeb.DashboardLive.Index`:
- **🛡️ Security & Threats Tab**: Dedicated executive dashboard tab showing portfolio-wide security health.
  - **Hero Metrics**: Domains at Risk, Critical CVEs & Flaws, Exposed Secrets / Repos, and Breached Accounts.
  - **Severity Distribution Bar**: Visual breakdown of critical, high, medium, low, and info findings across the entire organization.
  - **Priority Remediation Table**: Top 10 vulnerable domains ranked by weighted severity risk, linking directly to individual security reports.
  - **Recent Threat Detections**: Live feed of latest critical and high severity findings across the portfolio.
- **Operational Risks Alert Banner**: A prominent alert banner is displayed on the primary "Operational Risks" tab whenever high-risk security flaws are active, providing an instant **`Inspect Threats`** shortcut.

---

## 5. Security & Access Control

Access to security scanning is governed by role-based permissions:
- **Admin**: Full access. Can trigger single/bulk security scans, run heavy scans, and clear running scans.
- **Editor**: Can trigger standard native security scans and dark web breach lookups.
- **Viewer**: Read-only access. Can inspect reports, view finding details, and monitor dashboard posture. Mutation buttons are hidden and disabled.
