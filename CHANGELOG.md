# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Added

- **Bulk operations on domain listing** — select domains (individual, all visible, all matching filters) and execute actions
- Bulk actions: Scan, Delete, Set lifecycle status with confirmation modals
- **New lifecycle states**: `priority` (teal), `placeholder` (violet), `redirect` (cyan), `error` (red)
- Auto-detect lifecycle state after HTTP scan: external redirect → `redirect`, HTTP error → `error`
- **Quick scan button** on every domain/subdomain row with spinning animation and grayed-out state during scan
- **Rich domain listing rows**: HTTP status with redirect target, IP address, tech stack, last scanned time
- Clickable URLs in redirect chain and listing (open in new tab)
- **crt.sh fallback** for subdomain discovery when Chaos and HackerTarget fail
- HTTP fallback when HTTPS TLS fails (e.g., `campus-josera.pl`)

### Fixed

- Treat empty subdomain results as valid (no error flash)
- crt.sh timeout handling (8s timeout, graceful degradation)
- External redirect detection after full redirect chain follow

## [0.2.0] - 2026-04-28

### Added

- **Domain listing search, filter, pagination** with autocomplete suggestions
- Applied filters chips with individual clear buttons
- **Bulk import** with apex domain detection and import summary
- **RBAC** — role-based access control (viewer, editor, admin)
- User management and invite system

### Fixed

- Chaos API authentication header format
- HackerTarget "API count exceeded" error detection

## [0.1.0] - 2026-04-27

### Added

- Initial release
- Domain and subdomain management
- HTTP, DNS, RDAP, subdomain scanning
- Lifecycle state management (active, under_review, deprecated, decommissioned, abandoned)
- Basic TUI dashboard

[Unreleased]: https://github.com/guttenbergovitz/balebos/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/guttenbergovitz/balebos/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/guttenbergovitz/balebos/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/guttenbergovitz/balebos/releases/tag/v0.1.0
