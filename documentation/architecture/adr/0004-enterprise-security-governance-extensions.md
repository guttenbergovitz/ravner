# ADR 0004: Enterprise Attack Surface Management, SBOM, Secrets Detection & Unified Risk Architecture

**Status:** Accepted (Implemented)  
**Date:** 2026-09-26  
**Deciders:** Core Engineering Team  
**Consulted:** Ravner Architecture Team  

---

## 1. Context and Problem Statement

Following the successful implementation of ADR 0003 (Unified Observability & OpenTelemetry Semantic Telemetry), Ravner possesses a standardized BEAM `:telemetry` spine, real-time LiveView event inspector, and Prometheus `/metrics` scraper. 

However, to bridge the divide between raw technical probes and strategic organizational utility (operational readiness, European regulations like NIS2 and the Cyber Resilience Act, and SRE responsiveness), Ravner currently exhibits four functional gaps:

1. **Supply Chain Blind Spot (No SBOM Export)**:
   Ravner already extracts dependencies across 12 package ecosystems via `Ravner.Scans.ManifestParser` (`mix.lock`, `package-lock.json`, `poetry.lock`, `Cargo.lock`, `go.mod`, etc.) to query OSV.dev. However, it cannot generate or export a standardized **Software Bill of Materials (SBOM)** (such as CycloneDX 1.5 or SPDX). Enterprise security teams and regulatory auditors increasingly mandate machine-readable SBOMs for supply chain compliance.
2. **Repository Credential Leakage (No Secrets Detection)**:
   While Ravner connects to VCS providers (Bitbucket, GitHub, GitLab) and analyzes dependencies, it cannot detect hardcoded credentials (AWS keys, GitHub tokens, database connection URIs, private keys) accidentally committed to source repositories. Leaked secrets represent the #1 root cause of initial infrastructure compromise.
3. **Passive Alerting Disconnect (Lack of ChatOps Webhooks)**:
   While `Ravner.Uptime.Notifications` supports Email and SMS (Twilio/AWS SNS), modern engineering and SRE teams coordinate incidents inside Slack, Microsoft Teams, and Discord. The lack of webhook-based notifications forces operators to monitor dashboards manually.
4. **Cognitive Overload (Lack of an Executive Cyber Risk Score)**:
   Ravner collects hundreds of discrete data points per domain (CVE counts, SSL expiration dates, HSTS/CSP headers, uptime ratios, WCAG accessibility violations). Leadership, CISOs, and Project Managers require an aggregated, normalized health index (0–100 / Grade A–F) with actionable remediation drivers.

---

## 2. Decision Drivers

* **Zero Heavy External Binaries (In-Process Performance)**:
  Avoid bundling heavy, resource-intensive third-party binaries (e.g. TruffleHog, Syft, Trivy). Secrets detection and SBOM serialization must be written in pure Elixir/OTP, executing in-process with minimal CPU/RAM overhead and zero subprocess zombie risk.
* **Open Regulatory Standards**:
  Support **CycloneDX 1.5 JSON** (OWASP standard, recognized by CISA and EU Cyber Resilience Act) for SBOMs and standard webhook formats (Slack Block Kit, Teams Adaptive Cards, generic RFC payloads).
* **Adherence to the "Stop Line" Architecture**:
  * **Runtime Processing (Pure Ecto/Oban)**: Parsing repositories, matching secret regexes, and dispatching webhook alerts must bypass the Ash layer to maintain linear throughput and prevent lock contention.
  * **Governance & Access (Ash Framework)**: Policies dictating who can export SBOMs, configure webhook targets, or view unmasked secret findings must reside in Ash (`Ravner.Inventory.*`, `Ash.Policy.Authorizer`).
* **Normalized Persistence**:
  Findings (such as discovered secrets) MUST NOT be appended as growing JSON arrays in `domain_metadata`. They must be stored in dedicated, indexed tables (`project_repository_secrets`).
* **Use Existing Network Primitives**:
  Webhook delivery must use the already bundled `:req` HTTP client. No `:httpoison`, `:tesla`, or `:httpc`.

---

## 3. Considered Options

### Option 1: External CLI Wrappers (TruffleHog / Syft / Trivy)
Call third-party CLI tools via `Ravner.SystemCommand`.
* *Critique*: Substantial container bloat (hundreds of megabytes added to Docker images), slow invocation times, high memory footprints per Oban worker, and security risks associated with running external binary executors on untrusted repository contents.

### Option 2: Isolated Feature Additions without Architectural Integration
Implement webhook delivery as an ad-hoc task in individual workers and store secret findings in generic scan text blobs.
* *Critique*: Creates fragmentation, prevents cross-domain risk aggregation, duplicates HTTP notification logic, and violates data normalization mandates.

### Option 3: Native In-Process ASM & Governance Extension Suite (Selected)
Build a unified, modular 4-pillar extension on top of existing foundations:
1. **Supply Chain & SBOM**: Native `Ravner.Scans.SbomSerializer` transforming `ManifestParser` tuples into CycloneDX 1.5 JSON.
2. **Secrets Detection**: Pure Elixir regex engine + Shannon entropy calculation running in `RepoScanner` during repository checkout.
3. **Multi-Channel Webhook Notifier**: Extensible `:webhook` adapter in `Ravner.Uptime.Notifications` supporting Slack, Teams, and generic JSON webhooks via `:req`.
4. **Multi-Factor Risk Score Engine**: Deterministic, weighted composite scoring module (`Ravner.Governance.RiskScore`) evaluating vulnerabilities, SSL, uptime, headers, and accessibility.

---

## 4. Detailed Architectural Decision

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   RAVNER ENTERPRISE SECURITY & GOVERNANCE EXTENSIONS                   │
├─────────────────────┬─────────────────────┬─────────────────────┬─────────────────────┤
│   1. SBOM EXPORT    │  2. SECRETS SCAN    │  3. WEBHOOK ALERTS  │ 4. UNIFIED RISK     │
│   (CycloneDX 1.5)   │  (Regex & Entropy)  │  (Slack / Teams)    │    (0-100 / Grade)  │
├─────────────────────┼─────────────────────┼─────────────────────┼─────────────────────┤
│ • ManifestParser    │ • High-entropy keys │ • Slack Block Kit   │ • Vulnerabilities   │
│   (12 ecosystems)   │ • AWS, GitHub tokens│ • MS Teams Cards    │ • TLS / SSL expiry  │
│ • Component hashes  │ • Private RSA keys  │ • Idempotent Oban   │ • Uptime & SLA      │
│ • Direct JSON DL    │ • Masked storage    │ • Req HTTP client   │ • Security headers  │
└─────────────────────┴─────────────────────┴─────────────────────┴─────────────────────┘
```

### 4.1. Pillar 1: CycloneDX 1.5 SBOM Generation
* **Module**: `Ravner.Scans.SbomSerializer`
* **Input**: Manifest files parsed by `Ravner.Scans.ManifestParser`.
* **Output**: Valid CycloneDX 1.5 specification JSON containing:
  * `bomFormat`: `"CycloneDX"`
  * `specVersion`: `"1.5"`
  * `metadata.component`: Repository / Project details
  * `components`: Array of `{type: "library", name: ..., version: ..., purl: "pkg:<ecosystem>/<name>@<version>"}`.
* **Delivery**: Direct download endpoint at `/admin/projects/:id/sbom.cdx.json` and API endpoint protected by Ash policies.

### 4.2. Pillar 2: In-Process Secrets & Credential Detection
* **Module**: `Ravner.Scans.SecretsScanner`
* **Signatures**:
  * AWS Access Key ID (`AKIA[0-9A-Z]{16}`)
  * GitHub Personal Access Tokens (`ghp_[0-9a-zA-Z]{36}`, `github_pat_[0-9a-zA-Z_]{82}`)
  * GitLab Personal Access Tokens (`glpat-[0-9a-zA-Z\-_]{20,}`)
  * Private Keys (`-----BEGIN (RSA|OPENSSH|DSA|EC) PRIVATE KEY-----`)
  * Generic High-Entropy Tokens (Shannon entropy > 4.5 on strings > 20 characters assigned to `api_key`, `secret`, `password`)
  * Database Connection Strings (`(postgres|mysql|mongodb)://.*:.*@.*`)
* **Security & Storage**: Secrets are **never** stored in plaintext. Ravner stores a masked snippet (e.g. `AKIA************7X2A`), the file path, line number, commit SHA, and a SHA-256 fingerprint for deduplication in a dedicated table `project_repository_secrets`.

### 4.3. Pillar 3: Multi-Channel Webhook Notifications
* **Module**: `Ravner.Notifications.WebhookDispatcher`
* **Integration**: Woven directly into `Ravner.Uptime.Notifications` alongside SMS and Email.
* **Payload Adapters**:
  * **Slack**: Formats rich blocks with status color bars (red for downtime/critical, green for resolution), direct deep links to Ravner, and actionable incident metadata.
  * **Microsoft Teams**: Formats Adaptive Cards v1.4 compatible with enterprise Office 365 webhook connectors.
  * **Generic Webhook**: Dispatches standard OpenTelemetry / CloudEvents JSON payloads for ingestion into PagerDuty, Opsgenie, or custom SIEM systems.
* **Resilience**: Enqueued through Oban queue `:notifications` with automatic retry backoff and deduplication.

### 4.4. Pillar 4: Unified Cyber Risk Score (0–100 / Grade A–F)
* **Module**: `Ravner.Governance.RiskScore`
* **Mathematical Model**:
  $$\text{RiskScore} = \text{clamp}\left(100 - (\Delta_{\text{vuln}} + \Delta_{\text{ssl}} + \Delta_{\text{uptime}} + \Delta_{\text{headers}} + \Delta_{\text{secrets}}), 0, 100\right)$$
  * $\Delta_{\text{vuln}}$: 25 pts per Critical CVE, 10 pts per High CVE.
  * $\Delta_{\text{secrets}}$: 20 pts per unmitigated secret leak.
  * $\Delta_{\text{ssl}}$: 30 pts for expired cert, 15 pts if expiry < 14 days, 10 pts for TLS 1.0/1.1 enabled.
  * $\Delta_{\text{uptime}}$: Up to 20 pts deducted proportionally if 30-day uptime < 99.9%.
  * $\Delta_{\text{headers}}$: Up to 15 pts deducted for missing HSTS, CSP, or Clickjacking protection.
* **Grading Scale**:
  * `90–100`: **Grade A** (Excellent posture)
  * `80–89`: **Grade B** (Good, minor hygiene issues)
  * `65–79`: **Grade C** (Moderate risk, missing headers or approaching SSL expiry)
  * `50–64`: **Grade D** (High risk, High CVEs or poor availability)
  * `< 50`: **Grade F** (Critical risk, active leaks or Critical unpatched CVEs)

---

## 5. Consequences and Trade-offs

### Positive
* **Zero Infrastructure Bloat**: No external Docker sidecars, Python scripts, or Go binaries. All 4 features run purely within BEAM/Elixir.
* **High Business & Compliance Value**: Instant fulfillment of NIS2 and Cyber Resilience Act SBOM requirements, direct ChatOps alerting, and executive visibility.
* **Operational Peace of Mind**: Zero background scheduler proliferation; all scanning runs through existing Oban jobs and manual UI triggers.

### Negative / Mitigations
* **False Positive Risk in Secrets**: High-entropy strings (e.g. test fixtures, mock UUIDs) can produce false alarms.  
  *Mitigation*: Implement a strict file-path exclude list (e.g., `test/fixtures/**`, `*.sample`, `*.example`) and UI allowlisting ("Mark as False Positive / Ignored").
* **Webhook Network Timeouts**: External webhook endpoints (Slack, Teams) may experience transient network timeouts.  
  *Mitigation*: Dispatched asynchronously via Oban with exponential backoff and a 5-second HTTP timeout using `:req`.

---

## 6. Compliance and Security Notes

* Secrets detected in repositories are masked prior to database persistence to prevent Ravner itself from becoming a credential exposure target.
* SBOM exports contain no proprietary source code—only dependency coordinates, versions, and package URLs (purl).
* Webhook endpoints are validated to prevent internal SSRF attacks (disallow private IP ranges unless explicitly opted-in).
