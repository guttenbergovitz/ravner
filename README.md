# Ravner

Domain and infrastructure inventory management system. Built for speed, precision, and zero-nonsense visibility.

## Overview

Ravner is an automated discovery and security auditing engine designed to map infrastructure and surface risks without the bloat. It handles everything from DNS/RDAP lookups to deep technology stack detection and port-level vulnerability scanning.

## Core Discovery Pipeline

The system operates on a multi-stage discovery model, which can be triggered manually or automated via schedules:

1.  **Identity**: DNS resolution (`dnsx`) and registration details (`rdap/whois`).
2.  **Reachability**: HTTP probing (`httpx`) to determine status, final URLs, and server headers.
3.  **Topology**: Subdomain enumeration via passive and active sources (Chaos, HackerTarget, crt.sh).
4.  **Security**: Port discovery (`naabu`) and targeted vulnerability scanning (`nuclei`) scoped to high-impact findings.
5.  **Intelligence**: Technology stack fingerprints via `webanalyze` (Wappalyzer) and deep crawling via `katana`.
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

## Development

### Prerequisites

- Elixir 1.16+
- PostgreSQL
- External tools (must be in `$PATH`):
  - `dnsx`, `httpx`, `naabu`, `nuclei`, `katana`, `webanalyze`, `whois`

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

Detailed specifications and architectural notes are kept in the `/documentation` directory:

- `/documentation/features` — Specific feature designs (Bulk ops, Security scans).
- `/documentation/architecture` — System design, command execution, and scheduling.
- `/documentation/architecture/roadmap.md` — Identified bottlenecks and future scaling plans.
- `/documentation/architecture/ash-migration-plan.md` — Ash Framework adoption strategy.
- `/documentation/architecture/ash-migration-checklist.md` — Completed migration steps and regression checks.
- `/documentation/heuristics` — Rules for classification and discovery logic.
