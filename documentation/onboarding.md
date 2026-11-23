# Ravner Engineering & System Onboarding Guide

Welcome to **Ravner**. This document serves as the primary onboarding manual for software engineers, systems operators, and LLM-based autonomous agents. It explains the core purpose, domain model, architectural principles, operational pipelines, and development workflows.

---

## 1. System Purpose & Business Intent

### What is Ravner?
Modern enterprises operate hundreds or thousands of digital web properties across subsidiaries, acquired companies, cloud providers, and third-party SaaS platforms. This leads to **organizational blindness**:
- Unknown or forgotten websites running obsolete software.
- Unmaintained domain names vulnerable to expiration, takeover, or subdomain hijacking.
- Shadow IT and rogue landing pages bypassing security and accessibility compliance.
- Unclear ownership: when a critical CVE surfaces, security teams do not know who owns the repository, who the product manager is, or what business unit is responsible.

**Ravner** is an **Enterprise Attack Surface Discovery & Asset Governance Platform**. It solves organizational blindness by combining:
1. **Automated Discovery & Security Intelligence**: Continuously scanning DNS, HTTP, technology stacks, security headers, SSL certificates, open ports, web accessibility (WCAG / pa11y), performance (Lighthouse), and known vulnerabilities (CVEs via OSV.dev).
2. **Strict Corporate Governance & Ownership Tracking**: Mapping every domain to an explicit four-tier corporate hierarchy (Brand → Organization → Project → Person), enforcing role-based permissions, domain lifecycle state machines, and immutable audit trails.

---

## 2. Ownership Hierarchy & Domain Model

Ravner organizes corporate infrastructure into a clear four-tier relational hierarchy:

```
┌────────────────────────────────────────────────────────┐
│                        BRAND                           │
│  (e.g., Corporate Umbrella / Top-Level Holding Group)  │
└──────────────────────────┬─────────────────────────────┘
                           │ 1:N
┌──────────────────────────▼─────────────────────────────┐
│                    ORGANIZATION                        │
│     (e.g., Subsidiary, Business Unit, Division)        │
└──────────────────────────┬─────────────────────────────┘
                           │ 1:N
┌──────────────────────────▼─────────────────────────────┐
│                       PROJECT                          │
│     (e.g., Product Line, Platform, Web Initiative)     │
└──────────────┬──────────────────────────┬──────────────┘
               │ 1:N                      │ M:N
┌──────────────▼─────────────┐ ┌──────────▼──────────────┐
│           DOMAIN           │ │     PERSON & ROLES      │
│  (Root & Subdomain Assets) │ │ (PO, PM, Tech Lead, etc)│
└────────────────────────────┘ └─────────────────────────┘
```

- **Brand** (`Ravner.Inventory.Brand`): Represents the overarching enterprise identity. Can have an assigned executive **Brand Manager** (`belongs_to :brand_manager, Person`) for Level 3 escalation.
- **Organization** (`Ravner.Inventory.Organization`): Represents distinct legal entities, business units, or subsidiaries belonging to a Brand. Can have an assigned **Organization Manager** (`belongs_to :manager, Person`) for Level 2 company escalation.
- **Project** (`Ravner.Inventory.Project`): Represents a specific product, service, or business project. Projects maintain references to source code repositories (`ProjectRepository`).
- **Person** (`Ravner.Inventory.Person`) & **ProjectRole** (`Ravner.Inventory.ProjectRole`): Team members assigned to projects with defined responsibilities (Product Owner, Project Manager, Tech Lead).
- **Domain** (`Ravner.Domains.Domain`): Represents a fully qualified domain name (root or subdomain). Domains are assigned to Projects (or directly to Brands/Organizations if unassigned to a project) and feature a 3-tier governance escalation ladder.

---

## 3. The Hybrid Architecture ("The Stop Line" Mandate)

Ravner enforces a deliberate architectural split between **Governance** and **High-Volume Runtime Orchestration**:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        GOVERNANCE LAYER (ASH)                          │
│                                                                        │
│ • Inventory Management (Brands, Orgs, Projects, People, Roles)         │
│ • User Accounts & Centralized Authorization Policies                   │
│ • Domain Lifecycle State Transitions & Ownership Assignment            │
│ • Immutable Audit Logs via AshPaperTrail                               │
│ • Validations via Ash Actions & AshPhoenix.Form                        │
└───────────────────────────────────┬────────────────────────────────────┘
════════════════════════════════════╪═════════════════════════════════════
                       THE STOP LINE (Do NOT Cross)
════════════════════════════════════╪═════════════════════════════════════
┌───────────────────────────────────▼────────────────────────────────────┘
│                 PERFORMANCE RUNTIME (PURE ECTO / OBAN)                 │
│                                                                        │
│ • Asynchronous Scanners (DNS, HTTP, Ports, Tech Stacks, CVEs)          │
│ • High-Frequency Uptime Heartbeats & Downtime Detection                │
│ • Oban Dispatchers & Worker Queues                                     │
│ • Heavy Data Ingestion (URLs, Tech Evidence, DNS Records)              │
│ • Process Isolation via Ravner.SystemCommand (PGID management)         │
└────────────────────────────────────────────────────────────────────────┘
```

### Why this split?
- **Ash Framework** provides declarative policies (`Ash.Policy.Authorizer`), action contracts, and audit trails (`AshPaperTrail`). This is ideal for governance mutations where "who changed what, when, and with what authorization" matters.
- **Pure Ecto / Oban** eliminates framework overhead on high-frequency paths. When an asynchronous scan discovers 5,000 URLs or 50 DNS records, inserting them through Ash changesets would generate massive CPU and memory bloat. Bypassing Ash on the runtime hot path guarantees microsecond database throughput and linear scalability.

### Data Normalization Mandate
Never store unbounded growing collections (discovered URLs, technology evidence, DNS record lists) inside JSONB blobs in `domain_metadata`. Large discovery results must be written to dedicated 1:N normalized relational tables:
- `domain_dns_records` (`Ravner.Domains.DnsRecord`)
- `domain_tech_evidence` (`Ravner.Domains.TechEvidence`)
- `domain_discovered_urls` (`Ravner.Domains.DiscoveredUrl`)
- `heartbeat_checks` (`Ravner.Uptime.HeartbeatCheck`)

---

## 4. Security & Scanning Engine

### BEAM-First Native Probes
Where possible, Ravner avoids heavy external CLI tools and performs network operations natively inside the Erlang VM:
1. **DNS Resolution**: Native Erlang `:inet_res` queries (A, AAAA, CNAME, MX, TXT, NS).
2. **HTTP Probes**: Native `Req`-based HTTP client inspecting status codes, redirect chains, server headers, and security headers (HSTS, CSP, X-Frame-Options).
3. **Technology Fingerprinting** (`Ravner.Scans.TechFingerprint`): Native pattern-matcher compiled against the official Wappalyzer signature database. The database is stored locally in `priv/wappalyzer/technologies.json` and updated automatically once a day by `Ravner.Workers.TechnologiesUpdateWorker`.
4. **Subdomain Enumeration**: Tiered passive discovery query chain:
   - Tier 1: ProjectDiscovery Chaos API (fastest for indexed assets).
   - Tier 2: HackerTarget API (broad public surface).
   - Tier 3: crt.sh (Certificate Transparency logs).

### Native 4-Phase Security Pipeline (`Ravner.Scans.SecurityRunner`)
To resolve Out-Of-Memory issues and high network footprints caused by monolithic scanners, Ravner uses a modular, lightweight security pipeline:
1. **Phase 1: Port Discovery (`Ravner.Scans.Naabu`)**: Fast, bounded discovery of top 100 common attack-surface ports.
2. **Phase 2: Curated Probes (`Ravner.Scans.CuratedProbes`)**: 30+ highly targeted, non-destructive HTTP probes checking for sensitive configuration files (`.env`, `.git/HEAD`, `/actuator/env`, database backups, exposed admin interfaces). All probes enforce strict 4 KB memory caps and content-validation heuristics to eliminate false positives.
3. **Phase 3: Real-Time Zero-Lag CVE Intelligence (`Ravner.Scans.CveLookup`)**: Zero-payload passive vulnerability correlation mapping detected technologies and versions against Google OSV.dev via dual-layer caching (L1 ETS + L2 PostgreSQL).
4. **Phase 4: TLS & Header Security Audit (`Ravner.Scans.TlsHeaderAudit`)**: Native Erlang `:ssl` handshake checks detecting deprecated TLS 1.0 / 1.1 protocols, combined with strict HTTP security header compliance verification (`HSTS`, `CSP`, `X-Frame-Options`, `X-Content-Type-Options`).

### Darknet Breach Intelligence
Independent of vulnerability scanning, `Ravner.SecurityScans.BreachDirectory` queries public breach dumps for leaked corporate credentials matching the target domain's email addresses, providing security teams with visibility into compromised accounts.

### Process-Isolated CLI Runners (`Ravner.SystemCommand`)
When external security binaries must be executed (`naabu`, `katana`, `lonkero`, `pa11y`, `lighthouse`, `whois`), they must **always** be invoked through `Ravner.SystemCommand.run_with_timeout/4`.
- **Process Group Isolation (`PGID`)**: Commands run in independent process groups so child threads cannot detach.
- **Zombie Mitigation**: If a command exceeds its configured timeout or the parent crashes, SIGTERM followed by SIGKILL is broadcast to the entire process group.

---

## 5. Continuous Uptime Monitoring & Alerting

Ravner includes a native, lightweight uptime monitoring engine (`Ravner.Uptime`):
1. **Heartbeats**: `Ravner.Workers.HeartbeatWorker` sends fast HTTP HEAD/GET probes on a dedicated high-concurrency Oban queue (`heartbeats`, concurrency 50).
2. **History**: Every ping writes a lightweight record to `heartbeat_checks` measuring latency and availability. Old checks are pruned according to retention policies by `Ravner.Workers.HeartbeatRetentionWorker`.
3. **Downtime Detection**:
   - If consecutive failures reach the domain threshold (default: 2), a `DowntimeWindow` is opened and recorded in `downtime_windows`.
   - When the domain recovers, the window is closed, duration is computed, and recovery notifications fire.
4. **Multi-Channel Alerting**:
   - Dispatched asynchronously by `Ravner.Workers.UptimeNotificationWorker`.
   - **Email Channel**: Branded incident and recovery templates delivered via `Ravner.Mailer` (Swoosh).
   - **SMS Channel**: Behaviour-based adapter (`Ravner.Uptime.SmsAdapter`) supporting `AwsSns`, `Twilio`, and `Log` (for dev/test).
5. **Governance Notes**: Compliance operators can attach timestamped annotations and root-cause analysis notes (`Ravner.Uptime.DowntimeNote`) to any downtime window.

---

## 6. Access Control & RBAC

Authentication and authorization are enforced across router pipelines, LiveView mount hooks, and Ash resource policies:

| Role | Capabilities | Router Pipeline | Ash Policy |
|---|---|---|---|
| **Admin** | Full system administration, user management, API keys, mailer configuration, destructive actions. | `:require_admin` | `actor_attribute_equals(:role, :admin)` |
| **Editor** | Inventory CRUD (Brands, Orgs, Projects, People), domain management, triggering manual and bulk scans. | `:require_editor` | `actor_attribute_equals(:role, :editor)` |
| **Viewer** | Read-only visibility across domains, reports, and uptime status. Scan triggers and edit forms are hidden and disabled. | `:require_authenticated_user` | Read authorized; Mutations return `{:error, :forbidden}` |

### Deactivated Account Safeguard
Every user record has an `active` boolean flag. Deactivated users (`active: false`) are rejected at the session verification plug, token exchange, and magic link endpoints.

---

## 7. Development & Verification Workflow

### Prerequisites
- Elixir 1.16+ & Erlang/OTP 26+
- PostgreSQL 14+
- Optional external binaries for full scanning: `naabu`, `nuclei`, `katana`, `whois`

### Setup
```bash
mix setup
mix phx.server
```

### Precommit Standard
Ravner defines a strict `precommit` alias in `mix.exs`:
```bash
mix precommit
```
This alias runs:
1. `compile --warnings-as-errors`: Ensures zero compiler warnings.
2. `deps.unlock --unused`: Keeps dependencies clean.
3. `format`: Enforces official Elixir formatting.
4. `test`: Executes the full automated test suite.

Always run `mix precommit` before committing or finalizing changes.

---

## 8. Extension Playbooks

### A. Adding or Modifying an Ash Governance Resource
1. Place the resource in `lib/ravner/inventory/` or `lib/ravner/domains/`.
2. Define the resource with `use Ash.Resource`, configure `data_layer: AshPostgres.DataLayer`, and add `authorizers: [Ash.Policy.Authorizer]`.
3. If auditability is required, add `extensions: [AshPaperTrail.Resource]`.
4. Keep the context module (e.g., `Ravner.Inventory`) as a stable facade that accepts an `opts \\ []` keyword list and forwards `actor: opts[:actor]`.
5. Write context tests asserting authorization succeeds for `:admin`/`:editor` and fails with `{:error, :forbidden}` for unauthorized actors.

### B. Adding a Scheduled Background Worker
1. Create a worker in `lib/ravner/workers/my_worker.ex` with `use Oban.Worker, queue: :my_queue`.
2. If triggered by schedule, create a dispatcher in `lib/ravner/workers/my_dispatcher.ex`.
3. Register the cron schedule in `config/config.exs` under `config :ravner, Oban, plugins: [...]`.
4. Query target records using pure Ecto queries (never Ash queries inside the worker hot loop).
5. Always wrap external execution in `Ravner.SystemCommand.run_with_timeout/4`.

### C. Adding a LiveView Interface
1. Follow Phoenix v1.8 rules: Wrap templates in `<Layouts.app flash={@flash} current_scope={@current_scope} ...>`.
2. Access the current user via `@current_scope.user`.
3. Use Tailwind CSS utility classes and design system classes (`.btn-line`, `.input-line`, `.card-line`).
4. Support dark mode via `dark:` class variants.
5. Use LiveView streams (`stream/3`) for scalable collection rendering.
