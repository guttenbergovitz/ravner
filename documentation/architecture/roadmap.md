# Architecture Roadmap & Future Improvements

This document outlines known architectural bottlenecks and the planned technical evolution of Ravner as it scales.

## 1. JSONB Normalization (Status: Resolved)

- **Previous Bottleneck**: Storing unbounded arrays (`discovered_urls`, `tech_evidence`, `dns_records`) in `domain_metadata` JSONB columns caused I/O degradation and memory ballooning.
- **Implemented Solution**: High-volume discovery data was moved into dedicated 1:N normalized relational tables (`domain_discovered_urls`, `domain_tech_evidence`, `domain_dns_records`). Writes are performed via fast pure Ecto batch inserts (`sync_*` functions in `Ravner.Domains`), honoring the Stop Line rule.

## 2. Native BEAM Security Scanning & Resource Protection (Status: Resolved / Implemented)

- **Previous Bottleneck**: Heavy external Go CLI tools (especially `nuclei` and `lonkero`) consumed up to 2.5 GB of RAM per instance, risking container OOM exits (code 137) and triggering WAF rate limits.
- **Implemented Solution**: Fully implemented [ADR 0001: Native Lightweight Security Scanner](adr/0001-native-lightweight-security-scanner.md) in pure BEAM:
  - **Curated Probes (`Ravner.Scans.CuratedProbes`)**: In-process catalog of 35 targeted probes checking `.env`, `.git/HEAD`, Spring Actuator, backups, and cloud keys with a 4 KB response body cap.
  - **TLS & Header Security Audit (`Ravner.Scans.TlsHeaderAudit`)**: In-process `:ssl` deprecated TLS 1.0/1.1 handshake test and HTTP security headers audit (HSTS, CSP, X-Frame-Options).
  - **Zero-Lag CVE Intelligence**: In-process package matching against Google OSV.dev with dual-layer caching (`CveCache` ETS L1 + Postgres L2).
  - **Consolidated UI & Reporting**: Dedicated `/domains/:id/security` report page, bulk security scanning in domain listings, and a Portfolio Threat Posture tab on the main dashboard.
  - **Heavy Scanner Isolation**: External Nuclei and Lonkero runners are preserved strictly as optional on-demand heavy scans.

## 3. Temporal Visibility & Audit Trails (Status: Resolved / Implemented in v0.18.0)

- **Implemented**: 
  - Uptime history: `heartbeat_checks` and `downtime_windows` preserve full historical availability.
  - Domain & Inventory governance: `AshPaperTrail` is active on `Ravner.Domains.Domain`, `Ravner.Inventory.Brand`, `Ravner.Inventory.Organization`, `Ravner.Inventory.Project`, `Ravner.Inventory.Person`, `Ravner.Inventory.ProjectRole`, `Ravner.Inventory.Application`, and enterprise architecture resources.

## 4. Enterprise Governance via Ash Framework (Status: Core Implemented)

- **Status**: Transitioned `Ravner.Inventory.*`, `Ravner.Accounts.*`, and `Ravner.Domains.Domain` governance actions to Ash.
- **Stop Line Enforced**: Skaners, background dispatchers, heartbeats, and raw discovery persistence remain on pure Ecto/Oban to guarantee high I/O performance.
- **Next Step**: Modernize remaining LiveView filter controls to leverage AshPhoenix conventions where appropriate while preserving fast Ecto queries for large inventories.

## 5. Dual-Tree Scoped RBAC & Hierarchical Governance (Status: In Progress)

Reference: [ADR 0002: Dual-Tree Hierarchical Scoped RBAC](adr/0002-dual-tree-hierarchical-scoped-rbac.md)

- **Previous Bottleneck**:
  Flat 3-role model (`:admin`, `:editor`, `:viewer`) lacked resource isolation and failed to model the two intersecting organizational branches: Client Hierarchy (Brand ➔ Company ➔ Product Owner) vs. Delivery Hierarchy (Delivery Management ➔ Supervisor ➔ Cross-Company Project Manager).
- **Implementation Roadmap**:
  - **Milestone 1 — Data Layer & Scope Engine**:
    - Schema extensions: expand `users.role` enum, add `users.supervisor_id`, add `people.user_id`, add context fields to `user_invites`.
    - Pure functional `Ravner.Accounts.ScopeResolver` precomputing accessible entity IDs (`brand_ids`, `organization_ids`, `project_ids`, `domain_ids`, `supervised_pm_ids`).
    - Scope caching in `Ravner.Accounts.Scope` on session mount (`RavnerWeb.UserAuth`).
  - **Milestone 2 — One-Time Login Links**:
    - Secure 48-hour one-time login link generation (`Accounts.generate_one_time_login_link/2`) for managers over their subordinates.
    - Password set/reset workflow integration via `UserSessionController`.
  - **Milestone 3 — Ash Governance Policies & Authorizers**:
    - Policy updates on `Brand`, `Organization`, `Project`, `ProjectRole`, `Domain`, `UserResource`, `UserInviteResource`.
    - Strict enforcement: global roles (`:admin`, `:editor`, `:viewer`) are created and managed exclusively by `:admin`. Scoped roles can only create/invite subordinate roles within their tree.
  - **Milestone 4 — Runtime Query Scoping & Scan Guards**:
    - `Domains.list_domains/2` applies `where: d.id in ^scope.domain_ids` for scoped users; orphan assets restricted to `:admin` and `:editor`.
    - `SecurityRunner` and `RepoScanner` guard execution against `can_scan_domain?` / `can_scan_repo?`.
  - **Milestone 5 — Delegation & Management UI**:
    - `BrandShow`: Company creation and Company Manager appointment/invitation modal for Brand Managers.
    - `OrganizationShow`: Project creation and Product Owner appointment/invitation modal for Company Managers.
    - `DeliveryManagement`: Supervisor and PM team management, cross-company project assignments, and One-Time Login Link generation for Delivery Heads and Supervisors.
    - `ProjectShow`: PM repository controls, VCS sync, SCA dependency scans, and PO compliance/lifecycle views.

## 6. v0.18.0 Architectural Hardening & Remediation Rollout (Status: Completed in v0.18.0)

Reference: [Hardening & Remediation Plan](hardening-and-remediation-plan.md)

Following the v0.17.2 deep architectural audit, all six incremental phases were completed in v0.18.0:

1. **Phase 1 — Security, Ash Domain Authorization & CSRF Hardening**:
   - Enable `authorize(:always)` in `Ravner.Domains.AshDomain` and attach `Ash.Policy.Authorizer` + `ScopeReadCheck` to `DnsRecord`, `TechEvidence`, `DiscoveredUrl`, `DomainTag`, and `DomainMetadata`.
   - Enforce *deny-by-default* on `ScopeReadCheck.filter(nil, ...)` and support `%Scope{}` directly as actor to eliminate N+1 scope resolution queries during `Ash.load!`.
   - Remove the state-changing `GET /admin/unmasquerade` route.
2. **Phase 2 — Complete Governance Auditability & Admin Forms**:
   - Add `AshPaperTrail.Resource` and version table migrations (`people_versions`, `project_roles_versions`) for `Ravner.Inventory.Person` and `Ravner.Inventory.ProjectRole`.
   - Migrate `RavnerWeb.AdminLive.Users` forms from raw Ecto changesets to `AshPhoenix.Form` backed by `Ravner.Accounts.UserResource`.
3. **Phase 3 — External Command Isolation & Portable Process Groups**:
   - Route CLI calls in `Ravner.Admin.Backups` and `Ravner.ApiKeys` through `Ravner.SystemCommand.run_with_timeout/4`.
   - Replace synchronous `System.cmd` calls in `RavnerWeb.AdminLive.Settings` with `Path.wildcard/2` and asynchronous `SystemCommand` checks.
   - Add native `setsid` support in `Ravner.SystemCommand` for minimal container environments without `perl`.
4. **Phase 4 — Ash/Ecto Facade Error Propagation Cleanup**:
   - Map `Ash.Error.Invalid` fields onto `Ecto.Changeset` errors in `execute_ash_action/5` instead of returning an empty valid `fallback_changeset`.
5. **Phase 5 — LiveView Streams, Oban Scan Orchestration & Worker Test Suite**:
   - Migrate `RavnerWeb.DomainLive.Index` to Phoenix LiveView `stream/4`.
   - Route `ScanCoordinator` batch subdomain scans through `Ravner.Workers.ScanWorker` (Oban `:scans` queue) with `Phoenix.PubSub` notifications.
   - Add unit tests for the 13 untested Oban workers and dispatchers in `test/ravner/workers/`.
6. **Phase 6 — Static Typing (`@spec`), Tailwind v4 Compliance & Code Hygiene**:
   - Complete `@spec` annotations across `ApiKeys`, `A11y`, `Lighthouse`, `Domains`, `Inventory`, `Accounts`, and `Uptime`.
   - Replace all 47 `@apply` rules in `assets/css/app.css` with Tailwind v4 theme variables and native CSS.
   - Remove orphaned `form_component.html.heex`, replace `String.to_atom/1` in `Ravner.Scans.Dns` with compile-time atoms, and dynamically read the application version in `RavnerWeb.AshJsonApiRouter`.


