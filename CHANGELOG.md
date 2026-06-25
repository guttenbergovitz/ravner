# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.2] - 2026-06-25

### Fixed

- **Typography accessibility** — Bumped body/data text from `font-light` (300) to `font-normal` (400) for WCAG-compliant readability. Thin weight preserved only on decorative uppercase labels, H1 headings, and buttons where large size or letter-spacing compensate.

## [0.6.1] - 2026-06-25

### Fixed

- **Account settings discoverability** — Added visible "Account" link in the navigation for all authenticated users. Previously, non-admin users had no UI path to change their password or email (the route existed but was undiscoverable).

## [0.6.0] - 2026-06-14

### Added

- **Ownership Hierarchy Section** — New `/ownership` read-only views for navigating Brand → Organization → Project → People relationships with drill-down navigation, aggregated stats, and breadcrumbs. Separate from admin CRUD pages.
- **Admin Password Reset** — Three options for resetting user passwords from the admin panel: send a token-based reset link via email, generate and email a random password, or manually set a password.
- **User Deletion (Admin)** — Admins can delete users with built-in safeguards: cannot delete yourself, cannot delete the last admin.
- **Password Reset Flow** — New `UserResetPasswordController` with a public token-based reset form at `/users/reset-password/:token`.
- **Inactive User Lockout** — Users with `active=false` are now rejected across all authentication paths: password login, session token validation, and magic link login.
- **Role-Based UI Visibility** — Edit buttons in ownership views (Brand, Organization, Project, Person) are now conditionally rendered only for admin/editor roles.
- **Scan Button Access Control** — Domain scan action buttons are disabled for viewer-role users via the `scan_action_panel` component.
- **Bulk Discovery Tool Restriction** — "Add domain", "Import CSV", and "Scan visible" controls are hidden for viewers in the domain index view.

### Changed

- **Reset Password Token Validity** — Introduced a dedicated `@reset_password_validity_in_days` constant (1 day) instead of reusing the change-email token expiry.
- **`admin_delete_user/2` Actor Requirement** — The `:actor` option is now mandatory (raises on missing) to prevent silent use of a synthetic actor.
- **Scan Button CSS Consistency** — All scan buttons now include the viewer-disabled state in their visual class conditions (opacity, cursor), not just the `disabled` attribute.

### Fixed

- **Inactive User Session Hijack** — `get_user_by_session_token/1` now pattern-matches on `active: true`, preventing inactive users from maintaining valid sessions.
- **Magic Link for Deactivated Accounts** — Returns `{:error, :inactive}` with a user-facing message instead of silently failing.

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

[Unreleased]: https://github.com/guttenbergovitz/balebos/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/guttenbergovitz/balebos/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/guttenbergovitz/balebos/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/guttenbergovitz/balebos/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/guttenbergovitz/balebos/compare/v0.2.0...v0.3.0
