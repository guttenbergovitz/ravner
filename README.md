# Ravner

**Open-source Attack Surface Management, Domain Inventory, and Infrastructure Governance.**

Ravner helps engineering, security, and platform teams keep track of every domain, application, and repository they own — continuously checking DNS, SSL certificates, exposed ports, CVEs, web performance, accessibility, and supply-chain risks in one place.

---

## What Ravner Does

### 🌐 Attack Surface & Domain Monitoring
- **Automated Discovery** — Native DNS resolution, RDAP/WHOIS lookups, HTTP reachability & redirect tracking, and subdomain enumeration (Chaos, HackerTarget, crt.sh).
- **Technology Fingerprinting** — In-BEAM Wappalyzer matcher with automatic daily signature updates.
- **Security & CVE Auditing** — Port scanning (`naabu`), targeted vulnerability checks (`nuclei`), TLS & HTTP security header grading, OSV.dev CVE correlation, breach/infostealer exposure checks, and aggregated domain risk scores.
- **Uptime, Performance & Accessibility** — Continuous lightweight heartbeats, Google Lighthouse Core Web Vitals, and `pa11y` WCAG accessibility audits.

### 📦 Repository & Supply-Chain Security
- **Multi-Provider VCS Integrations** — Connect **GitHub**, **GitLab**, or **Bitbucket** workspaces to link repositories to projects and domains.
- **SCA & Secret Scanning** — Detect vulnerable dependencies via OSV.dev and leaked credentials/tokens in repositories.
- **SBOM Export** — Generate **CycloneDX 1.5** Software Bills of Materials.

### 🏛️ Ownership & Enterprise Landscape
- **Ownership Hierarchy** — Organize assets across **Brands → Organizations → Projects → People** with escalation contacts.
- **Digital Landscape Modeling** — Map **Applications**, **Datastores**, **External Services**, **Hosting Environments**, **Business Capabilities**, and **Value Streams**, with **ArchiMate 3.1 XML** and **Mermaid** exports.

### 🔐 Governance, API & Integrations
- **Role-Based Access Control & Audit Trail** — Fine-grained `Admin`, `Editor`, and `Viewer` roles with scoped permissions, invite flows, and full change history (`AshPaperTrail`).
- **REST / JSON:API & Swagger** — Declarative JSON:API v1.1 endpoints with OpenAPI/Swagger UI and IP/path-scoped API tokens.
- **Observability & Alerting** — Prometheus `/metrics` endpoint, OpenTelemetry instrumentation, plus Email, SMS (Twilio / AWS SNS), and ChatOps webhook notifications.
- **MCP Server for AI Tools** — Built-in Model Context Protocol endpoint (`POST /mcp`) allowing IDEs and AI agents (Cursor, Claude Code, Windsurf) to query and manage governance data safely under your RBAC policies.

---

## Quick Start (Local Development)

### Prerequisites
- **Elixir** `1.16+` and **Erlang/OTP** `27+`
- **PostgreSQL** `16+`
- **Node.js** (for assets/Lighthouse/pa11y, if running those scans locally)
- **External scanner binaries** in `$PATH` (needed only for active deep scans):
  - `naabu`, `nuclei`, `katana`, `whois`
  *(DNS resolution, HTTP probing, and Wappalyzer fingerprinting run natively inside Elixir — no `dnsx`, `httpx`, or `webanalyze` required.)*

### Setup & Run

```bash
# Install dependencies, create & migrate the database, and build assets
mix setup

# Start the Phoenix server
mix phx.server
```

Then open [http://localhost:4000](http://localhost:4000).
In development, outgoing emails are captured locally at [http://localhost:4000/dev/mailbox](http://localhost:4000/dev/mailbox).

### Common Dev Commands

```bash
mix test              # Run the test suite
mix precommit         # Run formatting, checks, and tests before committing
mix credo --strict    # Lint and code style checks
mix dialyzer          # Static type analysis
```

---

## Docker & Production Deployment

Ravner ships with a multi-stage [Dockerfile](Dockerfile) that builds a self-contained OTP release bundled with the runtime scanner binaries.

### Environment Variables

| Variable | Description |
|---|---|
| `DATABASE_URL` | PostgreSQL connection URL (e.g. `ecto://user:pass@host/ravner_prod`) |
| `SECRET_KEY_BASE` | Phoenix secret key base (generate with `mix phx.gen.secret`) |
| `PHX_HOST` | Public hostname (e.g. `ravner.example.com`) |
| `PORT` | HTTP port (default: `4000`) |
| `METRICS_BEARER_TOKEN` | Optional bearer token to protect the Prometheus `/metrics` endpoint |
| `RAVNER_MCP_API_KEY` | Optional API key for the `/mcp` Model Context Protocol server |
| `RAVNER_MCP_ACTOR_EMAIL` | Actor email used for audit attribution on MCP requests |
| `CHAOS_API_KEY` | Optional ProjectDiscovery Chaos API key for subdomain discovery |
| `SMTP_HOST` / `SMTP_PORT` | SMTP server host and port (typically `587` for STARTTLS) |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | SMTP authentication credentials |
| `SMTP_MAIL_FROM` | Sender email address (e.g. `noreply@example.com`) |

---

## Architecture at a Glance

Ravner uses a deliberate split between **governance** and **high-throughput scanning**:

- **Phoenix LiveView + Tailwind CSS** — Real-time UI with light/dark mode and WCAG AA contrast.
- **Ash Framework** — Models governance domains (inventory ownership, RBAC policies, API tokens, domain lifecycle) with centralized authorization and audit trails.
- **Ecto + Oban** — Powers high-concurrency background scans, scheduling dispatchers, and bulk data ingestion without abstraction overhead.

---

## Documentation

Full architectural notes, ADRs, and feature guides live in [`/documentation`](documentation/index.md):

- [Documentation Index](documentation/index.md) — Overview of all guides and Architecture Decision Records (ADRs)
- [Onboarding Guide](documentation/onboarding.md) — System mental model and developer workflows
- [Architecture Roadmap](documentation/architecture/roadmap.md) — Scaling boundaries and future milestones

---

### HUMAN GENERATED CONTENT - DO NOT MODIFY

In dir `priv/repo/manual` there are .sql files with commands that I had to run to fix the issue with non-existing column `inserted_at` in table `schema_migrations`

### END OF HUMAN GENERATED CONTENT - DO NOT MODIFY
