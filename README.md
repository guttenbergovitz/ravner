# Ravner

Domain and infrastructure inventory management system. Built for speed, precision, and zero-nonsense visibility.

## Overview

Ravner is an automated discovery and security auditing engine designed to map infrastructure and surface risks without the bloat. It handles everything from DNS/RDAP lookups to deep technology stack detection and port-level vulnerability scanning.

## Ownership Hierarchy

Ravner tracks domain ownership through a four-tier hierarchy:

- **Brand** — Top-level corporate identity (e.g., company umbrella)
- **Organization** — Business unit or subsidiary within a brand
- **Project** — Product or initiative within an organization
- **People** — Team members with roles assigned to projects

The `/ownership` section provides read-only drill-down views with aggregated statistics (domain counts, team sizes, repository links). Admin CRUD operations remain in `/admin/*` routes.

## Core Discovery Pipeline

The system operates on a multi-stage discovery model, which can be triggered manually or automated via schedules:

1.  **Identity**: DNS resolution (native `:inet_res`) and registration details (`rdap/whois`).
2.  **Reachability**: HTTP probing (native, `Req`-based) to determine status, final URLs, and server headers.
3.  **Topology**: Subdomain enumeration via passive and active sources (Chaos, HackerTarget, crt.sh).
4.  **Security**: Port discovery (`naabu`) and targeted vulnerability scanning (`nuclei`) scoped to high-impact findings.
5.  **Intelligence**: Technology stack fingerprints via a native Wappalyzer matcher (`Ravner.Scans.TechFingerprint`, database auto-updated daily) and deep crawling via `katana`.
6.  **Persistence**: Continuous uptime monitoring via lightweight heartbeats.

## Automation & Scheduling

Ravner utilizes **Oban** for reliable background task processing and persistent scheduling. 

- **Granular Intervals**: Configure independent schedules for Heartbeats (minutes), HTTP scans (days), DNS scans (days), and full Security scans (days) per domain.
- **Dispatcher Pattern**: Efficient database-driven scheduling that scales to thousands of domains without queue bloat.
- **Observability**: Real-time queue monitoring and schedule management via the Admin Jobs dashboard.

## Engineering Standards

The project follows idiomatic Elixir/Phoenix patterns with a hybrid architecture:

- **Governance Layer (Ash Framework)**: Authorization (RBAC), Inventory management, and Domain lifecycle transitions are handled via **Ash Framework**. This provides declarative policies and automated audit trails (`ash_paper_trail`).
- **Performance Runtime (Pure Ecto/Oban)**: High-concurrency background scanning, process orchestration (`Ravner.SystemCommand`), and heavy data ingestion (e.g., thousands of URLs) bypass Ash and use pure **Ecto/Oban** to avoid abstraction overhead and maintain maximum I/O performance.
- **Strict Typing**: All public context functions must have `@spec` annotations. Core data structures are defined via `@type t`.
- **Clean Execution**: External tools are wrapped by `Ravner.SystemCommand` to ensure proper process group cleanup and timeout management.
- **Documentation**: Professional `@moduledoc` and `@doc` annotations are required for both developers and LLM-based agents.

## UI & Theming

- **Dark mode** — Full dark theme with class-based toggle (`.dark` on `<html>`). All pages, components, and admin views support both light and dark modes.
- **Accessibility** — WCAG AA contrast ratios, keyboard-navigable dropdowns (WAI-ARIA Menu Button), global focus-visible indicators.
- **Design system** — Custom Tailwind CSS component classes (`.btn-line`, `.input-line`, `.card-line`, `.table-line`) with automatic dark mode support via `app.css` layer.

## Access Control & Authentication

Ravner implements role-based access control with three user roles:

| Role | Capabilities |
|------|-------------|
| **Admin** | Full system access — user management, password resets, user deletion, all CRUD operations, scan triggers, settings |
| **Editor** | Create/edit governance entities (organizations, projects, people, brands), trigger scans, manage domains |
| **Viewer** | Read-only access to all views — scan buttons disabled, edit links hidden, bulk tools unavailable |

### Authentication paths

All authentication paths enforce an `active` flag check:

- **Password login** — rejected if `user.active == false`
- **Session token** — invalidated for inactive users (pattern match on `active: true`)
- **Magic link** — returns `{:error, :inactive}` with a user-facing message

### Admin user management

Admins can manage users through `/admin/users`:

- **Create users** with email, role, name, and temporary password
- **Edit** role, name, and active status
- **Reset passwords** via three methods: token link (email), random password (email), or manual entry
- **Delete users** with safeguards (cannot delete self, cannot delete last admin)
- **Invite flow** with time-limited tokens for onboarding new team members

## Model Context Protocol (MCP) Server

Ravner includes a native Model Context Protocol (MCP) server powered by `ash_ai` and `req_llm`, mounted at `/mcp`. It exposes Ash-managed governance resources as structured tools for LLM agents, developer IDEs (Cursor, Claude Code, Windsurf), and automated workflows:

- **Endpoint**: `POST /mcp` (Streamable HTTP / JSON-RPC 2.0)
- **Supported Auth**: `Authorization: Bearer <TOKEN>`, `X-API-Key: <TOKEN>`, `X-MCP-Token: <TOKEN>`, or user session tokens.
- **Environment Variables**: Configure `RAVNER_MCP_API_KEY` (and optional `RAVNER_MCP_ACTOR_EMAIL`).
- **Policy & Audit Guarantees**: Tool execution propagates the authenticated actor to Ash actions, enforcing `Ash.Policy.Authorizer` checks and logging mutations to `AshPaperTrail` (`domains_versions`, `projects_versions`).
- **Stop Line Architecture**: Exposes only governance domains (`Ravner.Domains.AshDomain`, `Ravner.Inventory.AshDomain`, `Ravner.Accounts.AshDomain`). High-volume background scanners, Oban worker queues, and external command execution remain on pure Ecto/Oban and are excluded from LLM tools.

## Development

### Prerequisites

- Elixir 1.16+
- PostgreSQL
- External tools (must be in `$PATH`):
  - `naabu`, `nuclei`, `katana`, `whois`

  DNS resolution, HTTP probing and technology fingerprinting run natively
  inside the BEAM — no `dnsx`, `httpx` or `webanalyze` binaries needed.
  The Wappalyzer fingerprint database is fetched automatically on first boot
  and refreshed daily by `Ravner.Workers.TechnologiesUpdateWorker`.

### Setup

```bash
mix setup
mix phx.server
```

### Tooling

- `mix test` — Run the suite.
- `mix credo --strict` — Style and code quality.
- `mix dialyzer` — Static analysis.
- `mix format` — Enforce formatting.

## Documentation

Detailed specifications and architectural notes are organized in the `/documentation` directory:

- [`/documentation/index.md`](documentation/index.md) — Master documentation index and architecture navigation.
- [`/documentation/onboarding.md`](documentation/onboarding.md) — System onboarding manual for engineers, operators, and LLMs.
- `/documentation/features` — Specific feature designs (Uptime monitoring, Bulk ops, Security scans, Access control).
- `/documentation/architecture` — System design, command execution, and scheduling.
- `/documentation/architecture/roadmap.md` — Technical roadmap, bottlenecks, and scaling milestones.
- `/documentation/architecture/ash-migration-plan.md` — Ash Framework adoption strategy.
- `/documentation/architecture/ash-migration-checklist.md` — Implementation tracking and regression checklist.
- `/documentation/heuristics` — Rules for classification and discovery logic.

## Deployment

Ravner is packaged as a standard OTP release via the included `Dockerfile` (multi-stage build with runtime scanner binaries).

### Required & Common Environment Variables

| Variable | Description |
|---|---|
| `DATABASE_URL` | PostgreSQL connection string (e.g., `ecto://user:pass@host/ravner_prod`) |
| `SECRET_KEY_BASE` | Phoenix secret key base (`mix phx.gen.secret`) |
| `PHX_HOST` | Public hostname (e.g., `ravner.example.com`) |
| `PORT` | HTTP port (default `4000`) |
| `METRICS_BEARER_TOKEN` | Optional bearer token protecting `/metrics` Prometheus endpoint |
| `RAVNER_MCP_API_KEY` | Optional API key for the MCP governance server |
| `RAVNER_MCP_ACTOR_EMAIL` | Actor email used for MCP audit attribution |
| `CHAOS_API_KEY` | Optional ProjectDiscovery Chaos API key for subdomain discovery |

### Email / SMTP

Production email delivery uses SMTP via Swoosh. Set the following environment variables in your container runtime:

| Variable | Description |
|---|---|
| `SMTP_HOST` | SMTP server hostname |
| `SMTP_PORT` | SMTP port (typically `587` for STARTTLS) |
| `SMTP_USERNAME` | SMTP authentication username |
| `SMTP_PASSWORD` | SMTP authentication password |
| `SMTP_MAIL_FROM` | Sender address for all outgoing emails (e.g., `noreply@example.com`) |

In development, emails are captured locally and viewable at `/dev/mailbox` (Swoosh Local adapter).


### HUMAN GENERATED CONTENT - DO NOT MODIFY

In dir `priv/repo/manual` there are .sql files with commands that I had to run to fix the issue with non-existing column `inserted_at` in table `schema_migrations`

### END OF HUMAN GENERATED CONTENT - DO NOT MODIFY
