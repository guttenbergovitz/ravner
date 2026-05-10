# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-05-09

### Added

- **Oban-based Task Scheduling** — Integrated Oban for reliable, PostgreSQL-backed background task processing and persistent scheduling.
- **Granular Automation** — Added configurable intervals for Heartbeats (minutes), HTTP scans (days), DNS scans (days), and full Security scans (days) per domain.
- **Dispatcher Pattern** — Implemented a scalable, database-driven scheduling model that handles thousands of domains without queue bloat.
- **Uptime Heartbeats (Internal Status monitor)** — Lightweight heartbeat system for continuous availability monitoring, decoupled from heavy security scans.
- **Admin Jobs Dashboard** — A dedicated administrative view at `/admin/jobs` for real-time queue monitoring and unified schedule management.
- **Architecture Roadmap** — Documented the long-term technical evolution plan, including JSONB normalization and tooling abstraction.

### Changed

- **UI Component Decomposition** — Refactored the `DomainLive.Show` "god-file" into reusable FunctionComponents (`DomainComponents`) and a state-isolated `SecurityPostureComponent`.
- **Lean security scanner** — single `Run Security Scan` action chains httpx → naabu → tightly-scoped nuclei (critical/high only). Persists derived metadata including `open_ports`, `tech_stack`, and `hosting_platform`.
- **Documentation Overhaul** — Centralized and modernized the project documentation with a focus on engineering standards and discovery pipelines.
- **Unified Disabled State** — Scan triggers are now globally synchronized; initiating any scan type properly grays out all other triggers to prevent concurrency conflicts.

### Fixed

- **Boolean Attribute Rendering** — Fixed a `Protocol.UndefinedError` by ensuring Ecto structs are not passed directly to HTML boolean attributes.
- **Upsert Metadata Logic** — Fixed a bug where unsetting intervals to `nil` was ignored by the database during upsert operations.

## [0.4.0] - 2026-05-02

### Added

- **Strict typing and static analysis** — integrated Dialyxir and Credo into the development workflow.
- **SSL monitoring** — integrated certificate extraction (issuer, validity, status) using Erlang's `:ssl` and `:public_key`. Includes SNI support for modern TLS servers and a dedicated Admin overview page.
- **Improved scan UX** — added "Scan all subdomains" and "Scan visible" actions, grouped individual scans under a "Discovery" accordion.
- **Enhanced scan resilience** — improved HTTP error handling (recording status 0 on failures) and detection of insecure (HTTP-only) sites as errors.
- **Form validation** — missing error messages restored on registration and account settings forms.

### Changed

- **Codebase refactoring** — broken down "God Modules":
    - Extracted `DashboardStats` to its own module.
    - Refactored `Domains` query builder to use idiomatic functional pipelines.
    - Simplified `Scans` fallback logic using `Enum.find_value/3`.
- **LiveView optimization** — reduced cyclomatic complexity by using pattern matching for event handlers and extracting filter parsing logic.
- **Documentation** — added comprehensive `@spec`, `@type`, and `@doc` annotations for better human and LLM onboarding.

### Fixed

- **LiveView stability** — prevented crashes caused by unhandled or malformed background scan result messages.
- **UI bugs** — fixed broken HEEx string interpolation in the top navigation logout button.
- **Production readiness** — replaced unsafe `Mix.env()` calls in application logic with `Application.get_env/2`.

## [0.3.0] - 2026-04-28

...

[Unreleased]: https://github.com/guttenbergovitz/balebos/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/guttenbergovitz/balebos/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/guttenbergovitz/balebos/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/guttenbergovitz/balebos/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/guttenbergovitz/balebos/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/guttenbergovitz/balebos/releases/tag/v0.1.0
