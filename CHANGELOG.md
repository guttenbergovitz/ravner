# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.18.3] - 2026-11-17

### Fixed

- **Scan Completion Crash & Error Popup Handling (`DomainLive.Show`, `ScanCoordinator`)**:
  - Updated `DomainLive.Show.reload_domain/2` to use `Domains.get_domain_with_preloads!/1` so `:application` is always preloaded after scan completion, preventing `KeyError` crashes in `ShowTechnicalTab`.
  - Fixed `Protocol.UndefinedError` in `ScanCoordinator.handle_scan_done/4` when interpolating `{:dns, :no_ips}` and added human-readable formatting for atom/tuple errors from `Scans.Dns` and `Scans.Http`.
  - Consolidated `"Run all scans"` (`:all`) flash notifications into a single summary flash instead of overwriting four consecutive flashes.
  - Added `notify_flash/3` in `SecurityPostureComponent` so LiveComponent errors and status updates propagate to the parent LiveView flash.
  - Prevented failed A11y/Lighthouse scans from overwriting the latest completed scan in UI state and guarded `Calendar.strftime/2` against `nil` `completed_at` in `ScanQualityPanels`.
  - Enabled live PubSub updates on `A11yReport` and `LighthouseReport` after clicking rescan.

### Changed

- **Lifecycle Scan Gating & Ecosystem Security Summary**:
  - Enforced `Domain.scannable?/1` (`[:priority, :active, :under_review]`) across `ScanCoordinator`, `ScanPanel`, `SecurityPostureComponent`, `SecurityReport`, `SelectionCoordinator`, `A11y`, and `Lighthouse`, and deduplicated `external_redirect?/2` via `Ravner.Scans.external_redirect?/2`.
  - Filtered `SecurityScans.portfolio_security_summary/1` to scannable lifecycle states so archived, placeholder, and redirect domains are excluded from ecosystem security metrics.
- **Governance & Permission UX Consistency**:
  - Unified disabled button states and tooltips across `ScanPanel`, `ScanQualityPanels`, `LifecycleDropdown`, `IndexRow`, and `ShowGovernanceTab` (`Brand`, `Organization`, `Project` selects and `Read-only` indicator) when the actor lacks `can_scan?` or `can_manage?`.
  - Scoped `Inventory.list_*` and `Domains.suggest_domains/3` in `DomainLive.Index` to `current_scope` and added a `PageSpeed` report link in `DomainLive.Show`.
  - Flattened `SecurityRunner.run_light_pipeline/4` into a single `with` pipeline and replaced raw `String.to_existing_atom/1` tab parsing in `SecurityReport` with an explicit map.

## [0.18.2] - 2026-10-27

### Changed

- **Domain LiveView HEEx Template Modularization**:
  - Extracted the Technical Overview and Ownership & Governance tabs from `lib/ravner_web/live/domain_live/show.html.heex` into dedicated functional component modules (`RavnerWeb.DomainLive.ShowTechnicalTab` and `RavnerWeb.DomainLive.ShowGovernanceTab`), reducing `show.html.heex` from 2,041 lines to 250 lines (-88%).
  - Extracted the Faceted Search Sidebar, stream row item, and Bulk/Domain modals from `lib/ravner_web/live/domain_live/index.html.heex` into dedicated functional component modules (`RavnerWeb.DomainLive.IndexSidebar`, `RavnerWeb.DomainLive.IndexRow`, and `RavnerWeb.DomainLive.IndexModals`), reducing `index.html.heex` from 1,441 lines to 530 lines (-63%).

## [0.18.1] - 2026-10-27

### Fixed

- **Bulk & Scan Visible Crash with "Include Subdomains" Enabled**:
  - Preloaded `:subdomains` in `Ravner.Domains.list_domains_by_ids/2` and guarded unloaded `#Ash.NotLoaded{}` relationships in `RavnerWeb.DomainLive.SelectionCoordinator` and `Ravner.Domains.to_csv/1` to prevent `Protocol.UndefinedError` when scanning or modifying visible/selected domains with subdomains included.

## [0.18.0] - 2026-10-26

### Added

- **Governance Audit Trail for People & Project Roles (`AshPaperTrail`)**:
  - Enabled `AshPaperTrail.Resource` on `Ravner.Inventory.Person` and `Ravner.Inventory.ProjectRole` with dedicated `people_versions` and `project_roles_versions` tables.
  - Added `Ravner.Inventory.list_person_versions/1` and `Ravner.Inventory.list_project_role_versions/1` to inspect identity and role assignment revisions.
- **Centralized Ash-to-Ecto Error Translation (`Ravner.AshErrorHelpers`)**:
  - Added `Ravner.AshErrorHelpers.to_ecto_changeset/2` to map `Ash.Error.Invalid`, `Ash.Error.Forbidden`, and unknown Ash errors directly onto `Ecto.Changeset` field and base errors across `Ravner.Domains`, `Ravner.Inventory`, and `Ravner.Accounts`.
- **Oban Dispatcher Unit Test Suite**:
  - Added comprehensive unit tests in `test/ravner/workers/dispatchers_test.exs` covering `HeartbeatDispatcher`, `DomainCheckDispatcher`, `HttpxScanDispatcher`, `DnsxScanDispatcher`, `SslCheckDispatcher`, `SecurityScanDispatcher`, `A11yScanDispatcher`, `LighthouseScanDispatcher`, `HeartbeatRetentionWorker`, and `UptimeNotificationWorker`.
- **Architectural Hardening & Remediation Documentation**:
  - Added [`documentation/architecture/hardening-and-remediation-plan.md`](documentation/architecture/hardening-and-remediation-plan.md) documenting the 6-phase security, governance, and scalability rollout.

### Changed

- **LiveView Streams for Domain Inventory (`RavnerWeb.DomainLive.Index`)**:
  - Migrated the domain listing table in `DomainLive.Index` to `@streams.domains` (`phx-update="stream"`) with scalar `@domains_count` and `@domains_empty?` assigns to prevent BEAM process memory ballooning on large inventories.
- **Oban-Orchestrated Subdomain Batch Scanning (`RavnerWeb.DomainLive.ScanCoordinator`)**:
  - Replaced unthrottled `Task.Supervisor` fan-out in `handle_scan_all_subdomains/1` with `Oban.insert_all/1` jobs on `Ravner.Workers.ScanWorker` and `Phoenix.PubSub` progress notifications on `DomainLive.Show`.
- **Admin User Management Form (`RavnerWeb.AdminLive.Users`)**:
  - Migrated the user role/supervisor edit form to `AshPhoenix.Form.for_update/3` backed by `Ravner.Accounts.UserResource` (`:admin_update`).
- **Process Group (`PGID`) Isolation & Portable Session Leader (`Ravner.SystemCommand`)**:
  - Extended `Ravner.SystemCommand.run_with_timeout/4` with custom `env` support, direct absolute executable paths, and native `setsid` binary detection with `perl` fallback for minimal container images.
  - Routed external CLI invocations in `Ravner.Admin.Backups`, `Ravner.ApiKeys`, and `RavnerWeb.AdminLive.Settings` (using `Path.wildcard/2` and `start_async/3`) through `Ravner.SystemCommand`.
- **Tailwind CSS v4 Native Styling (`assets/css/app.css`)**:
  - Replaced all `@apply` directives with native CSS properties and Tailwind v4 theme variables (`var(--color-neutral-*)`).
- **Static Typing & Code Hygiene**:
  - Completed `@spec` annotations across public functions in `Ravner.Domains`, `Ravner.Inventory`, `Ravner.Accounts`, `Ravner.ApiKeys`, `Ravner.A11y`, `Ravner.Lighthouse`, and `Ravner.Uptime`.
  - Replaced runtime `String.to_atom/1` in `Ravner.Scans.Dns` with compile-time atoms and dynamically resolved the OpenAPI specification version in `RavnerWeb.AshJsonApiRouter` from `Application.spec(:ravner, :vsn)`.
  - Removed orphaned `lib/ravner_web/live/domain_live/form_component.html.heex`.

### Fixed

- **Real-Time Activity Drawer Telemetry for Quick & Background Scans**:
  - Propagated `user_id` from `SelectionCoordinator` and `ScanCoordinator` into `ScanWorker`, `A11yScanWorker`, and `LighthouseScanWorker`, and into the `Task.async` RDAP lookup in `Ravner.Scans.run_quick_scan/1`, so `RavnerWeb.ActivityDrawerLive` receives real-time step-by-step progress.
  - Added start, completion, and failure activity events to `Ravner.Scans.run_quick_scan/1`, `Ravner.Scans.Http.run_httpx_scan/1`, and `Ravner.Scans.Ssl.run/1`.
- **Manual Quick Scan Blocked by Completed Oban Jobs**:
  - Scoped `Ravner.Workers.ScanWorker` uniqueness to `states: :incomplete` (`period: 1_800`) so completed scans no longer silently suppress subsequent manual quick scans for 30 minutes.

### Security

- **Default Ash Domain Authorization & Child Resource Policies**:
  - Enabled `authorize(:by_default)` on `Ravner.Domains.AshDomain` and `Ravner.Inventory.AshDomain`.
  - Added `Ash.Policy.Authorizer` and `Ravner.Accounts.ScopeReadCheck` policies to `DnsRecord`, `TechEvidence`, `DiscoveredUrl`, `DomainTag`, and `DomainMetadata` to prevent cross-scope data exposure via Ash/MCP queries.
  - Updated `ScopeReadCheck.filter/3` to fail closed (`false`) when `actor` is `nil` and to accept pre-resolved `%Ravner.Accounts.Scope{}` structs directly.
- **CSRF Protection on Masquerade Termination**:
  - Removed state-changing `GET /admin/unmasquerade` route in `RavnerWeb.Router`, restricting session unmasquerading to CSRF-protected `POST` and `DELETE` requests.
- **Binary Session Token Integrity in `RequireMcpAuth`**:
  - Preserved 32-byte raw binary session tokens without `String.trim/1` corruption when leading or trailing bytes match ASCII whitespace characters.

## [0.17.3] - 2026-10-24

### Fixed

- **Technology filter click handler** — Missing `"technology"` case in `toggle_facet` event handler caused silent failure when clicking tech facets.

## [0.17.2] - 2026-10-21

### Added

- **Hierarchical technology filter** — Technologies now grouped by base name with expandable versions (PHP → PHP 7.4.33, PHP 8.1.6). Click base name to filter all versions, or expand to filter specific version. Comma-separated tech strings split into individual entries.

### Fixed

- **Redirect/placeholder domains excluded from risk scoring** — `RiskScore.recalculate_for_domain/1` now returns N/A for domains where `Domain.hide_scoring?/1` is true (placeholder, redirect_internal, redirect_external). Previously these domains had misleading security ratings.
- **Technology filter noise** — Filtered out marketing text, company names (GmbH, Inc.), Elementor plugin settings, and other non-technology entries from tech_stack display.

## [0.17.1] - 2026-10-21

### Fixed

- **Bulk scan crash on listing** — `ScanWorker.finish_scan` lacked clause for raw map result from `run_quick_scan`, causing `FunctionClauseError`. Added `finish_scan(%{} = _result, ...)` clause.
- **Stuck spinning icons after scan failure** — Crash prevented PubSub notification, leaving UI in scanning state. Now properly notifies on all result types.
- **Excessive scan retries** — Added `max_attempts: 3` to `ScanWorker` (was Oban default of 20).

## [0.17.0] - 2026-10-21

### Added

- **Technology filtering for domain listing** — Filter domains by detected technologies (WordPress, Drupal, NextJS, PHP, Node, etc.) via new facet in sidebar. Uses PostgreSQL array overlap for `domain_metadata.tech_stack`.

- **Enhanced background jobs panel** (`/admin/jobs`):
  - Real-time executing breakdown by worker type with pulse animation.
  - Cancel button for running/scheduled jobs via `Oban.cancel_job`.
  - "Cancel All Executing" bulk action.
  - Worker type filter dropdown.
  - Domain name resolution for scan jobs instead of raw args.
  - 3-second auto-refresh for live monitoring.

### Fixed

- **Risk scoring hidden for placeholder/redirect domains** — Cyber Risk & Executive Posture card now shows "Risk Scoring Not Applicable" message instead of misleading scores.
- **Security report redirect for non-scannable domains** — Redirects placeholder/redirect domains back to domain show with info message.
- **Missing `@impl` annotation** — Added to `bulk_scan_done` handler for LiveView callback consistency.

## [0.16.1] - 2026-10-21

### Fixed

- **crt.sh timeout handling** — Timeout returns `{:error, :timeout}` instead of empty success.
- **prune_old_scans race condition** — Rewrote to atomic subqueries eliminating SELECT→DELETE race.
- **SIGKILL orphan prevention** — Heavy scans use `Task.Supervisor.start_child` with proper shutdown linkage.
- **Batch insert findings** — Added `rescue` clause catching constraint violations on duplicate inserts.
- **Hudson Rock 404 handling** — Validates response body before treating as success.
- **finalize_scan atomicity** — Wrapped scan finalization in Ecto transaction.
- **External API retries** — Added `HttpRetry` module with exponential backoff and jitter.
- **Global scan deadline** — Light scans: 5 min, heavy scans: 10 min hard limits.
- **DNS error typing** — Returns typed errors `:nxdomain`, `:timeout`, `:servfail` instead of generic failure.
- **API key startup validation** — Logs warnings for missing required keys at boot.
- **Error message truncation** — All `error_message` fields capped at 500 chars.

## [0.16.0] - 2026-10-08

### Added

- **Declarative REST API via AshJsonApi (v1.1) and OpenAPI 3.0 / Swagger UI**:
  - Implemented declarative JSON:API endpoints for digital governance & inventory:
    - `/api/v1/applications` & `/api/v1/applications/:id` (`Ravner.Inventory.Application`)
    - `/api/v1/projects` & `/api/v1/projects/:id` (`Ravner.Inventory.Project`)
    - `/api/v1/organizations` & `/api/v1/organizations/:id` (`Ravner.Inventory.Organization`)
    - `/api/v1/brands` & `/api/v1/brands/:id` (`Ravner.Inventory.Brand`)
    - `/api/v1/domains` & `/api/v1/domains/:id` (`Ravner.Domains.Domain`)
  - Automated OpenAPI 3.0 specification derivation at `/api/v1/open_api`.
  - Mounted interactive **Swagger UI** under `/api/swagger-ui`.
  - Added direct link to Swagger UI with `OpenAPI` badge under the Admin top navigation dropdown.
  - Documented architectural decision in [`ADR 0007`](documentation/architecture/adr/0007-ash-json-api-openapi-swagger-architecture.md) establishing the "fire-and-forget" contract automation and decoupling from Schema.org.

- **Enterprise API Token Governance & Perimeter Defense (ADR 0008)**:
  - Added dedicated Admin UI for managing programmatic API tokens (`RavnerWeb.AdminLive.ApiTokens`) at `~p"/admin/api-tokens"`.
  - Secure by default: programmatic tokens default to `:viewer` (read-only) and `GET /api/v1/*` path scoping, requiring deliberate admin action to elevate privileges.
  - Granular perimeter control: source IP and CIDR subnet allowlisting (e.g. `192.168.1.50`, `10.0.0.0/16`) and HTTP method/URL path pattern scoping (e.g. `GET /api/v1/*`, `POST /api/v1/domains`).
  - Cryptographic credential security: raw token secret (`rav_live_...`) is shown strictly once to the administrator upon generation; database stores only irreversible SHA-256 digests.
  - Immediate lifecycle revocation and automatic expiry enforcement.
  - Centralized Ash policy enforcement on token actions restricted exclusively to `:admin` actors.
  - Documented decision in [`ADR 0008`](documentation/architecture/adr/0008-api-token-governance-source-and-url-scoping.md).

- **Digital Landscape & Enterprise Architecture Metamodel (BDAT / ArchiMate 3.1)**:
  - 12 new Ash governance resources: `Application`, `Datastore`, `HostingEnvironment`, `Registrar`, `NetworkAccess`, `ExternalService`, `ValueStream`, `BusinessCapability`, `ArchitectureConstraint`, and join resources.
  - AshPaperTrail enabled across digital landscape resources to trace modifications and regulatory changes.
  - Policy-as-Code constraints for European Accessibility Act (EAA / WCAG 2.1 AA), NIS2, DORA, and GDPR compliance.
  - Interactive UML-like architecture diagrams rendered dynamically via Mermaid in LiveView (`Ravner.Architecture.MermaidSerializer`).
  - Standard Open Group ArchiMate 3.1 Model Exchange XML exporter (`Ravner.Architecture.ArchiMateSerializer`) for ADOIT, Archi, and enterprise GRC platforms via `GET /projects/:project_id/export/archimate`.

- **Dedicated Application Management Hub** (`RavnerWeb.OwnershipLive.ApplicationShow`):
  - Accessible at `~p"/ownership/applications/:id"`.
  - Comprehensive workload management: edit metadata (type, criticality, lifecycle, hosting node).
  - Attached domains management with real-time candidate search, quick attach, and detach actions.
  - Datastore provisioning (PostgreSQL, Redis, MySQL, S3, MongoDB, Elasticsearch) with role assignment.
  - External SaaS/PaaS service linking (e.g. Stripe, Gadget.dev, Fivetran).
  - Policy-as-Code constraint registration and compliance tracking.
  - Audit trail viewing with historical revisions from `AshPaperTrail`.

- **Enterprise Landscape Catalog** (`RavnerWeb.OwnershipLive.Landscape`):
  - Accessible at `~p"/ownership/landscape"`.
  - Filterable catalog of applications with type filters (`storefront`, `api`, `cms`, `crm`, `pim`, `erp`, `portal`, etc.).
  - Strategic value stream overview and business capability mapping.
  - Direct deep links to manage individual applications and project topology views.

### Changed

- **Global Navigation Restructuring** (`root.html.heex`):
  - Reorganized top navigation into semantic hierarchy:
    - **Dashboard**: Unified overview.
    - **Inventory**: Dropdown linking Domains, Applications, and Code Repositories.
    - **Governance**: Dropdown linking Digital Landscape (BDAT), Brands & Organizations, and Delivery Hierarchy / Projects.
    - **Uptime**: Uptime and health monitoring.
    - **Admin**: Dedicated system administration (users, invites, telemetry, breach findings, certificates, jobs, settings).
- **Project Show Experience** (`OwnershipLive.ProjectShow`):
  - Added dedicated *Landscape* tab with live Mermaid topology, ArchiMate export button, and application cards linking directly to the management hub.
  - Integrated `+ Add Application` modal backed by `AshPhoenix.Form`.
- **Domain Overview** (`DomainLive.Show`):
  - Added registrar attribution badge and workload application indicators.

### Fixed

- **Breach Findings Admin UI** (`AdminLive.BreachFindingsLive`):
  - Added missing HTML template with table view and status actions
  - Fixed DB sorting (moved from in-memory `Enum.sort_by` to `order_by`)
  - Restored `/admin/certificates` route accidentally removed in previous commit
  - Admin navigation now includes both Breach Findings and SSL Certificates

## [0.15.0] - 2026-09-28

### Added

- **Redirect Lifecycle States** (`Ravner.Domains.Domain`):
  - New lifecycle states: `redirect_internal`, `redirect_external`
  - New fields: `redirect_target_url`, `redirect_target_domain_id`
  - Helper functions: `redirect?/1`, `redirect_internal?/1`, `redirect_external?/1`
  - `hide_scoring?/1` predicate for placeholder and redirect domains

- **Auto-Detection of Redirects** (`Ravner.Scans.Http`):
  - HTTP scans auto-detect redirects and set lifecycle state
  - Internal redirect: target host exists in DB, links to target domain
  - External redirect: target host not in DB
  - Stores redirect target URL and domain reference

- **Ownership Inheritance for Redirects** (`DomainLive.Show`):
  - Internal redirect domains display read-only inherited ownership
  - Brand, Organization, Project shown from target with "(inherited)" label
  - Links to target domain for navigation

- **Lighthouse Stale Scan Cleanup** (`Ravner.Lighthouse`):
  - `cleanup_stale_scans/0` marks scans stuck >5 min as failed
  - Called on domain show page alongside SecurityScans cleanup

### Fixed

- **VCS Domain Panel** (`VcsPanel`):
  - Updated to use new `token_type`/`repo_slug` form (removed legacy username field)

- **VCS Multiple Repository Tokens** (`VcsIntegration`):
  - Allow multiple repository tokens per workspace via partial unique indexes
  - Separate constraints for workspace vs repository tokens

### Changed

- **Security Posture for Redirects** (`SecurityPostureComponent`):
  - Placeholder and redirect domains show simplified message instead of scan controls
  - Internal redirects link to target domain
  - External redirects show target URL

- **Lifecycle Dropdown** (`DomainComponents`):
  - Added redirect states with distinct colors (sky/indigo)

## [0.14.0] - 2026-09-28

### Added

- **Repository-Scoped Bitbucket Access Tokens** (`VcsIntegration`, `Bitbucket`):
  - New `token_type` field: `workspace` (premium) or `repository` (single repo)
  - New `repo_slug` field for repository-scoped tokens
  - `test_connection` uses repo-specific endpoint for repository tokens
  - Settings UI with token type dropdown and conditional repo_slug input

### Removed

- **Deprecated App Password Support** (`VcsIntegration`):
  - Removed `username` field (Bitbucket App Passwords deprecated June 2026)
  - All authentication now uses Bearer tokens

### Changed

- **Generic UI Placeholders**:
  - Replaced business-specific placeholders with generic examples across VCS forms

## [0.13.0] - 2026-09-28

### Added

- **Lifecycle State Helpers** (`Ravner.Domains.Domain`):
  - `scannable_states/0` → `[:priority, :active, :under_review]`
  - `operational_states/0` → `[:priority, :active, :under_review, :placeholder]`
  - `archived_states/0` → `[:deprecated, :decommissioned, :abandoned]`
  - `scannable?/1`, `operational?/1`, `archived?/1`, `placeholder?/1` predicates

- **GUI Filter Toggles** (`DomainLive.Index`):
  - "Show archived" toggle to include deprecated/decommissioned/abandoned domains
  - "Hide placeholders" toggle to exclude placeholder domains
  - Default view now hides archived states for cleaner listings

### Changed

- **Scan Dispatchers Filter by Lifecycle** (`SecurityScanDispatcher`, `HttpxScanDispatcher`, `DnsxScanDispatcher`):
  - All scheduled scan dispatchers now filter to scannable states only
  - Placeholder, deprecated, decommissioned, and abandoned domains excluded from automatic scans

- **Report Views Filter by Lifecycle** (`Certificates`, `DomainRegistrations`):
  - Certificate and domain registration reports now show only operational domains
  - Archived domains excluded from expiration alerts and reports

- **Subdomain Inheritance** (`Ravner.Scans`):
  - New subdomains inherit parent's lifecycle state (archived states → `:under_review`)
  - New subdomains inherit parent's ownership (project_id, brand_id, organization_id)

## [0.12.0] - 2026-09-27

### Added

- **Model Context Protocol (MCP) Server for Ash Governance Domains** (`AshAi.Mcp.Router`, `RavnerWeb.Plugs.RequireMcpAuth`, ADR 0005):
  - Native Model Context Protocol (MCP) server integration using official `ash_ai` and `req_llm`, mounted at `/mcp` with Streamable HTTP and JSON-RPC 2.0 support.
  - Multi-tier authentication pipeline (`RequireMcpAuth`) supporting Bearer tokens, `X-API-Key`, `X-MCP-Token`, Basic Auth, and user session tokens with constant-time comparison (`Plug.Crypto.secure_compare/2`).
  - Automatic actor propagation (`Ash.PlugHelpers.set_actor/2`) to all Ash action invocations, ensuring strict declarative policy enforcement (`Ash.Policy.Authorizer`) and automated compliance audit logging (`AshPaperTrail`).
  - Governance tool catalog exposing 20 curated tools across `Ravner.Domains.AshDomain`, `Ravner.Inventory.AshDomain`, and `Ravner.Accounts.AshDomain` with explicit `select:` projection schemas.
  - Full adherence to the Hybrid Architecture "Stop Line" mandate, strictly keeping background scanner orchestration, external command execution, and Oban workers on pure Ecto/Oban while exposing only governance resources to LLMs.
  - Comprehensive integration test suite verifying handshake, tool listing, tool execution, role-based authorization rejection, and PaperTrail audit logging.

### Changed

- **Major Codebase Declutter** - Extracted coordinator modules to eliminate god objects and code duplication:
  - `RavnerWeb.VcsCoordinator` (299 LOC): Shared VCS sync, scan, connection, and modal logic across VcsPanel, ProjectShow, and AdminLive.Repositories.
  - `RavnerWeb.DomainLive.SelectionCoordinator` (358 LOC): Selection mode, bulk actions, and quick scan handling from DomainLive.Index.
  - `Ravner.Domains.SyncCoordinator` (226 LOC): DNS records, tech evidence, VCS tech, and URL batch sync operations.
  - `Ravner.Domains.ContactResolver` (327 LOC): Contact candidates, team lookup, and 3-tier escalation chain resolution.
  - `DomainLive.Index`: 1077 → 786 LOC (-27%)
  - `Ravner.Domains`: 1745 → 1190 LOC (-32%)

## [0.11.1] - 2026-09-27

### Fixed

- **ScanPanel LiveComponent Event Routing** (`RavnerWeb.DomainLive.ScanPanel`):
  - Added missing `phx-target={@myself}` to all scan buttons and scheduling form, ensuring events are handled by the component instead of bubbling to parent LiveView.
  - Fixed dead code in ScanPanel handlers that were never executed due to missing `phx-target`.

### Changed

- **ScanCoordinator Flash Compatibility** (`RavnerWeb.DomainLive.ScanCoordinator`):
  - Introduced `notify_flash/3` helper that works for both LiveView and LiveComponent contexts by sending `{:put_flash, kind, msg}` to parent process.
  - All `handle_scan_*` functions now use `notify_flash/3` for component compatibility.

- **Domain Show Declutter** (`RavnerWeb.DomainLive.Show`):
  - Removed 9 duplicate scan event handlers now properly delegated to ScanPanel component.
  - Reduced module size from 1,513 LOC to 529 LOC (65% reduction).
  - Retained only `scan_all_subdomains` handler used by `DomainComponents` subdomain bulk scan.

- **VcsPanel Flash Helper** (`RavnerWeb.DomainLive.VcsPanel`):
  - Renamed local `put_flash/3` to `notify_flash/3` to avoid conflict with imported `Phoenix.LiveView.put_flash/3`.

## [0.11.0] - 2026-09-26

### Added

- **CycloneDX 1.5 JSON SBOM Generation & Export** (`Ravner.Scans.SbomSerializer`, `RavnerWeb.SbomController`):
  - Automated, standards-compliant CycloneDX 1.5 JSON Software Bill of Materials generation meeting EU CRA, NIS2, and SOC2 software supply chain compliance requirements.
  - Deterministic Package URL (PURL) generation across Hex, npm, PyPI, Cargo, Go, Composer, and Gem ecosystems.
  - Secure download endpoints (`/admin/projects/:id/sbom.json` and `/admin/repositories/:id/sbom.json`) with RFC-compliant `application/vnd.cyclonedx+json` MIME typing and Ash actor authorization.
  - UI export action buttons on Project detail and Repository inspection cards.

- **In-Process VCS Hardcoded Secrets Detection & Triage** (`Ravner.Scans.SecretsScanner`):
  - High-precision pattern rules detecting AWS Access Keys, RSA/EC Private Keys, Slack Tokens & Webhooks, Database Connection URIs, GitHub/GitLab Tokens, and generic credentials in candidate VCS files.
  - Shannon entropy calculator (`shannon_entropy/1`) identifying high-entropy credential assignments while filtering placeholders and sample configs.
  - Secure cryptographic fingerprinting (`SHA-256`) and front-end masking (`mask_secret/1`) ensuring raw secrets never touch logs, DB, or client browsers.
  - Relational persistence in normalized `project_repository_secrets` table with status workflow (`active`, `resolved`, `false_positive`).
  - Interactive LiveView inspection modal for repository secrets triage and remediation.
  - Automated domain security scan integration registering `"repo_secrets"` findings into domain vulnerability reports.

- **Multi-Channel Webhook Dispatcher & ChatOps** (`Ravner.Notifications.WebhookDispatcher`):
  - Async Oban delivery (`WebhookNotificationWorker`) of critical CVE alerts, leaked secret findings, and SSL expiration warnings.
  - Native rich formatting adapters for Slack Block Kit, Microsoft Teams (Adaptive Cards v1.4), Discord, and Generic JSON (CloudEvents 1.0).
  - Robust SSRF protection blocking RFC1918 private subnets, AWS/cloud metadata services (`169.254.169.254`), loopbacks, and non-HTTP protocols.
  - HMAC-SHA256 signature verification via `X-Ravner-Signature-256` header.
  - Channel management UI in `RavnerWeb.AdminLive.UptimeNotifications` with interactive "Send Test Webhook" ping action.

- **Deterministic Cyber Risk & Executive Posture Scoring Engine** (`Ravner.Governance.RiskScore`):
  - Normalized 0–100 cyber risk index formula evaluating CVE impact, active leaked credentials, TLS/SSL certificate hygiene, missing security headers (HSTS, CSP, X-Frame-Options), downtime SLA, and exposed sensitive ports.
  - Executive letter grades: A+ (95–100), A (90–94), B (80–89), C (65–79), D (50–64), F (<50) with standardized Tailwind styling.
  - Normalized persistence in `domain_metadata` (`risk_score`, `risk_grade`, `risk_deductions`, `risk_drivers`).
  - Project-level aggregation (`calculate_for_project/1`) summarizing posture across all linked domains and repositories.
  - Automated recalculation hooks on security scan completion, SCA dependency scans, and secret triage status changes.
  - UI integration: executive grade badges on `/domains`, comprehensive Cyber Risk Posture Card on `/domains/:id` with on-demand recalculation, and posture metrics on `/ownership/projects/:id`.

- **Repository Dependency Vulnerability Scanner (Software Composition Analysis via OSV.dev)**:
  - Multi-ecosystem lockfile & manifest parsing (`Ravner.Scans.ManifestParser`): automatic detection and parsing of dependency graphs across 11 package lockfiles and manifests (`mix.lock`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `requirements.txt`, `composer.lock`, `go.mod`, `Cargo.lock`, `Gemfile.lock`).
  - Direct VCS manifest retrieval (`Ravner.Integrations.VCS.Bitbucket.fetch_file/4`) via `:req`.
  - Zero-API-key OSV.dev correlation with two-layer caching (`Ravner.Scans.CveCache` ETS + PostgreSQL).
  - Relational vulnerability persistence in `project_repository_vulnerabilities` with roll-up counters on `project_repositories`.
  - Interactive vulnerability inspection modal and domain security report integration.

## [0.10.0] - 2026-09-21

### Added

- **Domain View Tabbed Architecture (Nordic Line-art Tabs)**:
  - Re-engineered the domain details view (`/domains/:id`) with clean, focused tabs: **Technical Overview** (`?tab=technical`), **Ownership & Governance** (`?tab=governance`), and **Audit Trail** (`?tab=audit`).
  - **Technical Overview** now presents a clean, compact technical summary with a 1-line ownership bar and immediately surfaces HTTP, DNS, Tech Stack, URLs, and Scans without visual clutter.
  - **Ownership & Governance** dedicates a focused space for domain assignments (Brand, Org, Project, PM, PO) and the 3-Tier Escalation Hierarchy with direct interactive links to manage Company and Brand Managers in `/ownership`.
  - **Audit Trail** provides a dedicated, uncluttered compliance timeline of all governance state and assignment transitions.
- **Bitbucket & VCS Repository Integration for Projects & Domains**:
  - Implemented an extensible VCS adapter layer (`Ravner.Integrations.VCS`) with Bitbucket Cloud REST API v2 support (`Ravner.Integrations.VCS.Bitbucket`) via `:req`.
  - Secure zero-leak credential broker storing workspace-level credentials in `vcs_integrations` with token redaction and environment variable fallback (`BITBUCKET_WORKSPACE`, `BITBUCKET_APP_PASSWORD`), keeping sensitive tokens strictly off the client side.
  - Interactive "Link Repository" modal on Project Show (`/ownership/projects/:id?tab=repositories`) with live Bitbucket workspace browsing, search filtering, component kind selector, and manual URL fallback.
  - Direct repository linking on Domain Show (`/domains/:id`): added `domain_id` foreign key and `is_primary` flag on `project_repositories`, enabling code repos to be attached directly to a domain or inherited from its assigned project.
  - Multi-repository support per domain: domains can link multiple repositories (e.g. backend API, frontend web, microservices) with explicit primary vs. component designations, 1-click primary designation changes, and per-repo sync and unlink actions.
  - Enriched Project Repositories List (`/ownership/projects/:id?tab=repositories`): displays repositories hanging directly on the project as "Project-wide" or with a clickable domain link and `(Primary)` indicator if attached to a domain.
  - Interactive "Source Code & Repositories" card in Technical Overview (`?tab=technical`) and quick links in the ownership bar, supporting 1-click project repo linking, live Bitbucket search, manual URL entry, on-demand synchronization, and unlinking.
  - Automated Multi-Repository Tech Stack Aggregation: syncing or linking/unlinking repositories automatically detects technologies across all linked repositories and aggregates them into `domain_tech_evidence` as 100% confidence ground-truth evidence (`vcs:provider`), preserving HTTP crawler observations while updating `domain_metadata.tech_stack`.
  - Real-time commit pulse tracking showing latest commit hash, commit message, author, and relative timestamp per repository.
  - On-demand synchronization (`sync_repo`) and unlinking (`unlink_repo`) actions for project managers and administrators.
- **Brand & Company Management & Security Risk Posture**:
  - Re-engineered Brand Manager and Company Manager designation UX with live candidate search and 1-click selection cards in modals, backed by fallback select dropdowns.
  - Added prominent actionable callouts with direct "Assign Now" buttons on unassigned leadership cards.
  - Aggregated security risk posture metrics (`domains_at_risk_count`, `critical_count`, `high_count`) per Brand and Company, prominently integrated into stats counter headers.
  - Enriched domains lists on Brand Show and Organization Show with scanner-observed technical status indicators, lifecycle state dots, and organization/project badges.
  - Added unmanaged manager alerts to the `/ownership` overview cards and "Needs Attention" sidebar for brands and organizations without designated managers.

### Fixed

- **CVE lookup false positives** — Fixed an issue where empty version strings (`""`) in technology evidence were queried against OSV.dev, returning all historical vulnerabilities for unversioned packages (e.g. PHP).
- **Direct vs. implied tech distinction** — Technologies inferred via Wappalyzer `implies` rules (e.g. PHP from CMSs, Node.js from Express) are now tagged as `wappalyzer:implied` with 50% confidence, displayed with an `implied` badge in UI, and excluded from passive CVE queries unless direct version evidence exists.
- **Debian wontfix CVE filtering** — Filtered out unconstrained Debian advisories with `introduced: "0"` and no `fixed` event that erroneously matched all Nginx/Apache versions.
- **Database cleanup** — Added migration normalizing empty version strings to `NULL` and purging legacy false-positive CVE scan findings.
- **Client-side & JavaScript redirect following** — The HTTP scanner (`Ravner.Scans.Http`) now detects and follows client-side redirects (JavaScript `window.location` and `<meta http-equiv="refresh">`) on stub/landing pages. Domains returning HTTP 200 with JavaScript redirects to parking platforms (e.g. GoDaddy/Afternic for-sale pages) or external forms are now correctly resolved and marked as `:redirect` instead of `:reachable`.


## [0.9.1] - 2026-09-17

### Added

- **Direct Manager Assignment Workflows** — Reworked Brand and Company (Organization) views with fast inline and modal management controls:
  - Interactive manager assignment modals on Brand Show (`/ownership/brands/:id`) and Organization Show (`/ownership/organizations/:id`).
  - Single-click quick unassign actions with confirmation safeguards.
  - Reactive live updates in headers, leadership cards, and audit timelines without leaving the page.
- **Brand & Company Views Rework & 3-Tier Escalation Hierarchy**:
  - Re-engineered Brand Show with prominent **Brand Leadership & Escalation Hierarchy** card, displaying the designated Brand Manager and visual 3-tier escalation model (Frontline Companies ➔ Brand Portfolio ➔ Execution Layer).
  - Re-engineered Organization Show with **Company Leadership & Escalation Path** card, explicitly showing parent brand escalation routing and Brand Manager contacts.
  - Added dedicated **Governance Audit Trail** tabs on both Brand and Organization show pages consuming `AshPaperTrail` version logs.
- **Top-Level Navigation Promotion**:
  - Promoted `Ownership` to the primary top-level navigation bar alongside `Domains` and `Dashboard`.

### Fixed

- **Governance Audit Trail Timeline Layout & Contrast**:
  - Re-architected timeline from brittle negative positioning to a structured 2-column flex layout (`gap-3.5`), preventing dot indicators from overlapping event titles and text.
  - Fixed white-on-white and low contrast rendering by providing explicit high-contrast action borders and solid inner dots across all governance actions (`:set_lifecycle`, `:create`, `:update`, `:assign_contacts`, `:assign_brand_manager`, `:assign_manager`).
- **Dashboard High-Risk Security Banner Layout**:
  - Re-engineered the security alert card on `/dashboard` with balanced typography, visual hierarchy, metric summary chips (Critical, High, At Risk), and integrated threat inspection action.

## [0.9.0] - 2026-09-17

### Added

- **Brand Manager & Organization Manager Assignments** — Enhanced organizational governance with designated leaders at brand and organization levels:
  - `Ravner.Inventory.Brand`: Added `brand_manager_id` attribute, `belongs_to :brand_manager, Person` relationship, and explicit Ash action `:assign_brand_manager` tracked by `AshPaperTrail` in `brands_versions`.
  - `Ravner.Inventory.Organization`: Added `manager_id` attribute, `belongs_to :manager, Person` relationship, and explicit Ash action `:assign_manager` tracked by `AshPaperTrail` in `organizations_versions`.
  - Context APIs: Added `Ravner.Inventory.assign_brand_manager/3` and `Ravner.Inventory.assign_organization_manager/3` with `@spec` annotations.
- **3-Tier Governance Escalation Hierarchy** — Structured operational, corporate, and executive escalation chain across all managed domains:
  - Level 1 · Operational: Project Manager (`pm_email`) & Product Owner (`po_email`) assigned from Project roles.
  - Level 2 · Company / Organization: Organization Manager (`organization.manager`).
  - Level 3 · Executive / Brand: Brand Manager (`brand.brand_manager`).
  - Added `Ravner.Domains.domain_escalation_chain/1` to compute and resolve the complete 3-tier hierarchy.
- **Governance UI Surfaces**:
  - Domain Details (`/domains/:id`): Added dedicated **Governance Escalation Hierarchy** card displaying all 3 escalation tiers with status badges, manager contact links, and organization/brand directory routing.
  - Ownership Views (`/ownership`, `/ownership/brands/:id`, `/ownership/organizations/:id`): Added designated Brand Manager and Organization Manager cards with mailto and person directory links.
  - Admin Live Forms (`/admin/brands`, `/admin/organizations`): Added Brand Manager and Organization Manager dropdown pickers populated from the `Person` directory.

## [0.8.0] - 2026-09-17

### Added

- **Enterprise Inventory Audit Trail (`AshPaperTrail`)** — Extended `AshPaperTrail` governance audit tracking across all core organizational entities:
  - `Ravner.Inventory.Brand`: Tracks creation, updates, and destruction history in `brands_versions`.
  - `Ravner.Inventory.Organization`: Tracks creation, updates, and destruction history in `organizations_versions`.
  - `Ravner.Inventory.Project`: Tracks creation, updates, and destruction history in `projects_versions`.
  - Provided explicit context APIs with `@spec` annotations: `Ravner.Inventory.list_brand_versions/1`, `list_organization_versions/1`, and `list_project_versions/1`.
- **Domain Contacts & Project Team Governance** — Unified domain contacts with the Ash Framework governance architecture and project role directory:
  - Added explicit Ash action `:assign_contacts` on `Ravner.Domains.Domain` accepting `[:pm_email, :po_email]` governed by Ash policy (`:admin` and `:editor` roles).
  - Added `Ravner.Domains.assign_domain_contacts/3` delegating to Ash and generating compliant paper trail audit entries.
  - Integrated with `Ravner.Inventory.Person` via `Ravner.Domains.find_person_by_email/1` for rich person resolution.
  - Integrated with `Ravner.Inventory.ProjectRole` via `Ravner.Domains.project_team_candidates/1` to automatically discover and categorize project team members (`:pm`, `:po`, `:all`) assigned to the domain's project.
- **Interactive Assign Contacts UI** — Added modal dialog on `DomainLive.Show` (`/domains/:id`) with:
  - Project team quick-pick suggestion chips for Project Manager and Product Owner.
  - Manual email fallback input for external contacts.
  - Reactive live updates in the Details card and Governance Audit Trail timeline.

## [0.7.0] - 2026-09-17

### Added

- **Governance Audit Trail Timeline** — Interactive vertical timeline component on the domain details page (`/domains/:id`) displaying historical state transitions and ownership assignments recorded by `AshPaperTrail` in `domains_versions`.
- **Domain Version Context API** — Added `Ravner.Domains.list_domain_versions/1` with strict type annotations and safe atom deserialization to retrieve domain audit history.
- **Native BEAM-First Security Scanner** — Implemented ADR 0001 replacing heavy Nuclei CLI execution with an in-process 4-phase scanner:
  - Phase 1: Port Discovery (`naabu` with strict top-100 limit).
  - Phase 2: Curated Probes (`Ravner.Scans.CuratedProbes`) checking 30+ sensitive exposure endpoints with 4 KB memory caps.
  - Phase 3: Zero-Lag CVE Intelligence with real-time Google OSV.dev batch correlation and dual-layer caching (ETS + PostgreSQL).
  - Phase 4: TLS & Header Security Audit (`Ravner.Scans.TlsHeaderAudit`) detecting deprecated TLS 1.0/1.1 protocols and verifying modern HTTP security headers.
- **Dedicated Security Report** — Full-page technical finding analysis at `/domains/:id/security` with categorized tabs (Vulnerabilities, Sensitive Exposures, TLS & Headers, Open Ports, Darknet Breaches).
- **Bulk Security Scanning** — Support for multi-domain batch security scanning on `/domains` using `Task.async_stream` with configurable concurrency and synchronous domain task execution (`SecurityRunner.run_security_scan_sync/3`).
- **Security & Threat Posture Dashboard** — High-level portfolio threat intelligence widget and dedicated tab on `DashboardLive.Index`.

### Changed

- **UI Button Label Consistency** — Shortened long inspection button label to `"View Security Report"` with `whitespace-nowrap` to prevent line wrapping across screen sizes.
- **Breach Intelligence Separation** — Decoupled darknet email breach lookups from vulnerability scans to prevent state overwriting in domain posture drawer.

### Added

- **Full dark theme** — All 15 LiveView page templates now have `dark:` Tailwind variants. Surfaces, borders, text, hovers, active toggles, modals, filter chips, and pagination all adapt to dark mode. Toggle via the header moon/sun icon.
- **Keyboard-accessible admin dropdown** — Implemented WAI-ARIA Menu Button pattern: `tabindex="-1"` on menu items (arrow-key nav only), `aria-controls`, `focusout` handler for Tab, Home/End key support, fixed ArrowUp bug.
- **Focus-visible indicators** — Global `:focus-visible` outline rule for all interactive elements with dark mode variant.
- **Nav link contrast** — Inactive nav links upgraded from `neutral-500` to `neutral-600` for WCAG AA compliance.

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
