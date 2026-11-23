# Implementation Plan: Enterprise ASM, SBOM, Secrets Detection & Unified Risk Suite

This document defines the actionable, step-by-step rollout plan for implementing [ADR 0004](adr/0004-enterprise-security-governance-extensions.md).

---

## Architecture Overview

```
                      ┌───────────────────────────────────────────────┐
                      │    Ravner Scanners & Ingestion Pipeline       │
                      │    (RepoScanner, PortProbe, HeartbeatWorker)  │
                      └───────┬───────────────────────────────┬───────┘
                              │                               │
            ┌─────────────────┴─────────────┐   ┌─────────────┴─────────────────┐
            ▼                               ▼   ▼                               ▼
┌───────────────────────┐ ┌───────────────────────┐ ┌───────────────────────┐ ┌───────────────────────┐
│ Phase 1: SBOM Export  │ │ Phase 2: Secrets Scan │ │ Phase 3: Webhooks     │ │ Phase 4: Risk Score   │
│ (CycloneDX 1.5 JSON)  │ │ (Regex & Entropy)     │ │ (Slack, Teams, Req)   │ │ (0-100 / Grade A-F)   │
├───────────────────────┤ ├───────────────────────┤ ├───────────────────────┤ ├───────────────────────┤
│ • ManifestParser lock │ │ • In-process scanner  │ │ • Oban async delivery │ │ • Deterministic model │
│ • PURL generation     │ │ • Masked persistence  │ │ • Rich Slack blocks   │ │ • Vulnerability impact│
│ • Direct DL endpoint  │ │ • Dedicated DB table  │ │ • Teams adaptive cards│ │ • SSL & Uptime factors│
│ • Ash policy guard    │ │ • LiveView inspector  │ │ • Idempotent routing  │ │ • Executive gauges    │
└───────────────────────┘ └───────────────────────┘ └───────────────────────┘ └───────────────────────┘
```

---

## Phase 1: Software Bill of Materials (SBOM) Generation & Export

**Objective**: Provide automated, standards-compliant CycloneDX 1.5 JSON SBOM generation for all monitored projects and source repositories to satisfy EU Cyber Resilience Act, NIS2, and SOC2 software supply chain compliance requirements.

### Task 1.1: `Ravner.Scans.SbomSerializer`
* **File**: `lib/ravner/scans/sbom_serializer.ex`
* **Specification**: CycloneDX 1.5 JSON.
* **Input**: Dependencies extracted by `Ravner.Scans.ManifestParser.parse/2` (`[{name, version, ecosystem}]`).
* **Package URL (PURL) Mapping**:
  * Hex: `pkg:hex/<name>@<version>`
  * npm: `pkg:npm/<name>@<version>`
  * PyPI: `pkg:pypi/<name>@<version>`
  * crates.io: `pkg:cargo/<name>@<version>`
  * Go: `pkg:golang/<name>@<version>`
  * RubyGems: `pkg:gem/<name>@<version>`
  * Packagist: `pkg:composer/<name>@<version>`
* **Typespec**:
  ```elixir
  @spec generate(project_or_repo :: map(), dependencies :: [{String.t(), String.t(), String.t()}]) ::
          {:ok, map()} | {:error, term()}
  @spec to_json(map()) :: binary()
  ```

### Task 1.2: Controller & UI Download Actions
* **File**: `lib/ravner_web/controllers/sbom_controller.ex`
* **Routes**:
  * `GET /admin/projects/:id/sbom.json`
  * `GET /admin/repositories/:id/sbom.json`
* **UI**:
  * Add *"Export SBOM (CycloneDX)"* button to Project detail and Repository scan cards with direct file download (`application/vnd.cyclonedx+json`).

### Task 1.3: ExUnit Regression Tests
* **File**: `test/ravner/scans/sbom_serializer_test.exs`
* **File**: `test/ravner_web/controllers/sbom_controller_test.exs`
* Verify CycloneDX 1.5 schema compliance, purl encoding, and Ash authorization policies.

---

## Phase 2: In-Process Secrets & Credential Leak Detection

**Objective**: Detect committed credentials, API tokens, and private keys during repository scans without third-party binary bloat, preventing catastrophic infrastructure breach.

### Task 2.1: `Ravner.Scans.SecretsScanner`
* **File**: `lib/ravner/scans/secrets_scanner.ex`
* **Engine Architecture**:
  1. **Pattern Matching**: High-confidence regex rules for known token prefixes:
     * AWS Access Key ID (`AKIA[0-9A-Z]{16}`)
     * GitHub Tokens (`ghp_[0-9a-zA-Z]{36}`, `github_pat_[0-9a-zA-Z_]{82}`)
     * GitLab Personal Access Tokens (`glpat-[0-9a-zA-Z\-_]{20,}`)
     * Slack Webhooks & Tokens (`xox[baprs]-[0-9a-zA-Z]{10,48}`, `https://hooks.slack.com/services/...`)
     * SSH / RSA Private Keys (`-----BEGIN [A-Z ]*PRIVATE KEY-----`)
     * Database Connection URIs (`postgres://`, `mysql://`, `mongodb://`)
  2. **Shannon Entropy Filter**:
     * Calculates mathematical entropy on high-probability variable assignments (`api_key`, `secret`, `auth_token`, `password`). Strings with length > 20 and entropy > 4.5 are flagged as potential raw secrets.
  3. **Path Allowlisting / False Positive Exclusion**:
     * Excludes `.sample`, `.example`, `test/fixtures/**`, documentation files, and mock data.

### Task 2.2: Normalized Relational Schema
* **Migration**: `mix ecto.gen.migration create_project_repository_secrets`
* **Schema**: `lib/ravner/security_scans/secret_finding.ex`
  ```elixir
  schema "project_repository_secrets" do
    field :repository_id, :integer
    field :project_id, :integer
    field :file_path, :string
    field :line_number, :integer
    field :rule_id, :string
    field :masked_value, :string
    field :fingerprint_sha256, :string
    field :severity, :string, default: "critical"
    field :status, :string, default: "active" # active, resolved, false_positive
    field :commit_sha, :string
    timestamps()
  end
  ```

### Task 2.3: Wire into `Ravner.Scans.RepoScanner`
* Scan extracted non-binary files during repository checkouts.
* Emit `:telemetry` event `[:ravner, :synthetic, :secrets, :stop]`.
* Render secret findings in `RavnerWeb.AdminLive.RepositoriesLive` with one-click *"Mark as False Positive"* action.

---

## Phase 3: Multi-Channel ChatOps & Alerting (Slack, Teams, Webhooks)

**Objective**: Route immediate, actionable incident alerts to engineering teams where they communicate, closing the gap between problem detection and resolution.

### Task 3.1: Data Schema & Notification Channels
* Update `Ravner.Uptime.NotificationRecipient` to support channel `:webhook`.
* Recipient attributes: `url`, `webhook_type` (`"slack"`, `"teams"`, `"discord"`, `"generic"`), `secret_header`.

### Task 3.2: `Ravner.Notifications.WebhookDispatcher`
* **File**: `lib/ravner/notifications/webhook_dispatcher.ex`
* **HTTP Client**: Pure `:req` with 5s timeout and 3 retry attempts.
* **Payload Formatters**:
  * **Slack Block Kit**:
    ```json
    {
      "blocks": [
        {
          "type": "header",
          "text": {"type": "plain_text", "text": "🚨 Incident Detected: app.example.com is DOWN"}
        },
        {
          "type": "section",
          "fields": [
            {"type": "mrkdwn", "text": "*Project:*\nPayments Gateway"},
            {"type": "mrkdwn", "text": "*Error:*\nHTTP 502 Bad Gateway"}
          ]
        },
        {
          "type": "actions",
          "elements": [
            {"type": "button", "text": {"type": "plain_text", "text": "View in Ravner"}, "url": "https://ravner.internal/domains/42"}
          ]
        }
      ]
    }
    ```
  * **Microsoft Teams Adaptive Card**: v1.4 compatible cards with direct deep links.
  * **Generic RFC / CloudEvents Webhook**: Full JSON payload with HMAC-SHA256 signature header (`X-Ravner-Signature`).

### Task 3.3: Integration with Incident & Security Bus
* Trigger webhooks on:
  1. Uptime Incident opened / resolved.
  2. Critical CVE discovered in repository.
  3. Secret leak discovered in VCS.
  4. SSL certificate expiring in < 14 days.

---

## Phase 4: Unified Cyber Risk & Executive Posture Scoring

**Objective**: Provide executive leadership, CISOs, and Project Managers with a single, clear, deterministic 0–100 health index (and letter grade A–F) for every monitored domain and project.

### Task 4.1: Deterministic Risk Calculation Engine
* **File**: `lib/ravner/governance/risk_score.ex`
* **Formula**:
  $$\text{Score} = 100 - (\Delta_{\text{vuln}} + \Delta_{\text{secrets}} + \Delta_{\text{ssl}} + \Delta_{\text{uptime}} + \Delta_{\text{headers}})$$
* **Breakdown Structure**:
  ```elixir
  %{
    overall_score: 84,
    grade: "B+",
    deductions: %{
      vulnerabilities: 10,  # 1 High CVE
      secrets: 0,
      ssl: 0,
      uptime: 4,            # 99.8% availability (below 99.9% target)
      headers: 2            # Missing CSP
    },
    drivers: [
      "Missing Content-Security-Policy (CSP) header (-2 pts)",
      "1 High-severity CVE in npm dependencies (-10 pts)"
    ]
  }
  ```

### Task 4.2: Historical Persistence & Governance Views
* Store calculated score in `domain_metadata.risk_score` and `domain_metadata.risk_grade`.
* Add visual risk badges (`A+`, `A`, `B`, `C`, `D`, `F`) across:
  * Domains index table (`/domains`)
  * Projects overview (`/admin/projects`)
  * Executive Dashboard (`/admin/dashboard`)

---

## 5. Rollout Checklist

- [x] (Phase 1) Implement `Ravner.Scans.SbomSerializer` for CycloneDX 1.5 JSON.
- [x] (Phase 1) Add SBOM export download endpoint and UI buttons.
- [x] (Phase 1) ExUnit test coverage for SBOM generation.
- [x] (Phase 2) Implement `Ravner.Scans.SecretsScanner` (regex patterns + Shannon entropy).
- [x] (Phase 2) Migration and schema for `project_repository_secrets`.
- [x] (Phase 2) Integrate secrets scanning into `RepoScanner`.
- [x] (Phase 2) Display secret findings with masking in UI.
- [x] (Phase 3) Add `:webhook` channel to notification recipients.
- [x] (Phase 3) Implement `Ravner.Notifications.WebhookDispatcher` (Slack, Teams, Generic via `:req`).
- [x] (Phase 3) Wire webhooks into uptime incidents and critical security events.
- [x] (Phase 4) Implement `Ravner.Governance.RiskScore` calculation module.
- [x] (Phase 4) Render executive risk grades and breakdown cards on dashboards.
- [x] Run `mix precommit` and ensure 100% green test suite.
