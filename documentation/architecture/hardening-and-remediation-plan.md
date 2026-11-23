# Implementation Plan: Architectural Hardening, Security Remediation & Runtime Scalability (v0.18.0)

**Baseline Version:** `0.17.2`  
**Target / Released Version:** `0.18.0`  
**Status:** Completed (All 6 Phases Implemented & Verified)  
**Related Documents:**
- [ADR 0002: Dual-Tree Hierarchical Scoped RBAC](./adr/0002-dual-tree-hierarchical-scoped-rbac.md)
- [ADR 0005: AshAi Model Context Protocol (MCP) Server](./adr/0005-ash-ai-model-context-protocol-governance-server.md)
- [Ash and Ecto Domain Boundaries](./domain-boundaries.md)
- [Command Runner Architecture](./command-runner.md)

---

## 1. Executive Summary & Objectives

Following a comprehensive architectural audit of **Ravner v0.17.2** (597 tests passing, hybrid Ash 3.4 + Ecto 3.13/Oban 2.18 stack), this document defines the actionable 6-phase rollout plan to resolve remaining security edge cases, governance audit gaps, process isolation bypasses, LiveView memory scaling bottlenecks, and static typing debt.

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                   RAVNER v0.18.0 HARDENING & REMEDIATION PIPELINE                   │
└──────────────┬──────────────────────────┬──────────────────────────┬────────────────┘
               │                          │                          │
               ▼                          ▼                          ▼
┌────────────────────────────┐ ┌────────────────────────┐ ┌───────────────────────────┐
│ Phase 1: Security & Policy │ │ Phase 2: Governance    │ │ Phase 3: Process Isolation│
│ Hardening                  │ │ Audit & Ash Forms      │ │ & Stop Line Compliance    │
├────────────────────────────┤ ├────────────────────────┤ ├───────────────────────────┤
│ • Enable authorize(:always)│ │ • AshPaperTrail on     │ │ • Migrate Backups &       │
│   in Domains.AshDomain     │ │   Person & ProjectRole │ │   ApiKeys to SystemCommand│
│ • Policies on DnsRecord,   │ │ • Version migrations   │ │ • Async CLI checks in     │
│   TechEvidence, etc.       │ │ • Migrate Admin Users  │ │   AdminLive.Settings      │
│ • ScopeReadCheck deny-nil  │ │   to AshPhoenix.Form   │ │ • Native setsid fallback  │
│ • Remove GET unmasquerade  │ │                        │ │   when perl is absent     │
└──────────────┬─────────────┘ └────────────┬───────────┘ └─────────────┬─────────────┘
               │                            │                           │
               ▼                            ▼                           ▼
┌────────────────────────────┐ ┌────────────────────────┐ ┌───────────────────────────┐
│ Phase 4: Facade Error      │ │ Phase 5: LiveView      │ │ Phase 6: Static Typing,   │
│ Propagation Cleanup        │ │ Streams & Oban Queues  │ │ Tailwind v4 & Hygiene     │
├────────────────────────────┤ ├────────────────────────┤ ├───────────────────────────┤
│ • Map Ash.Error.Invalid to │ │ • LiveView streams in  │ │ • Complete @spec across   │
│   Ecto.Changeset errors    │ │   DomainLive.Index     │ │   7 public contexts       │
│ • Eliminate empty valid    │ │ • Route ScanCoordinator│ │ • Remove 47 @apply rules  │
│   fallback_changeset bug   │ │   batch scans via Oban │ │   in assets/css/app.css   │
│                            │ │ • 13 Oban worker tests │ │ • Remove dead templates   │
└────────────────────────────┘ └────────────────────────┘ └───────────────────────────┘
```

---

## 2. Phase 1: Security, Ash Domain Authorization & CSRF Hardening

**Objective:** Close cross-tenant read leaks in MCP/Ash queries, eliminate N+1 scope resolution overhead during Ash relationship loading, enforce *deny-by-default* when an actor is omitted on protected reads, and eliminate state-changing `GET` routes.

### Task 1.1: Enforce Authorization in `Ravner.Domains.AshDomain` & Child Resources
* **Problem:** `Ravner.Domains.AshDomain` currently has `authorization do authorize :always end` commented out, and child resources (`DnsRecord`, `TechEvidence`, `DiscoveredUrl`, `DomainTag`, `DomainMetadata`) lack `Ash.Policy.Authorizer`. When exposed via MCP tools (`list_domain_dns_records`, `list_domain_tech_evidence`), scoped actors can read DNS and technology records belonging to domains outside their assigned scope.
* **Target Files:**
  * `lib/ravner/domains/ash_domain.ex`
  * `lib/ravner/domains/dns_record.ex`
  * `lib/ravner/domains/tech_evidence.ex`
  * `lib/ravner/domains/discovered_url.ex`
  * `lib/ravner/domains/domain_tag.ex`
  * `lib/ravner/domains/domain_metadata.ex`
* **Implementation Details:**
  1. Uncomment and enable `authorization do authorize(:always) end` in `Ravner.Domains.AshDomain`.
  2. Add `authorizers: [Ash.Policy.Authorizer]` to `DnsRecord`, `TechEvidence`, `DiscoveredUrl`, `DomainTag`, and `DomainMetadata`.
  3. Define explicit policies on each child resource:
     ```elixir
     policies do
       policy action_type(:read) do
         authorize_if({Ravner.Accounts.ScopeReadCheck, []})
       end

       policy action_type([:create, :update, :destroy]) do
         authorize_if(actor_attribute_equals(:role, :admin))
         authorize_if(actor_attribute_equals(:role, :editor))
       end
     end
     ```
  4. Keep bulk runtime synchronization in `Ravner.Domains.SyncCoordinator` on pure Ecto (`Repo.insert_all/3`, `Repo.delete_all/2`) in strict compliance with the Stop Line mandate.

### Task 1.2: Harden `Ravner.Accounts.ScopeReadCheck` & Eliminate N+1 Scope Resolution
* **Problem:**
  1. `ScopeReadCheck.filter(nil, _context, _opts)` returns `true`, granting full read access whenever an Ash query is executed without an `actor`.
  2. `ScopeReadCheck.filter(%User{} = actor, ...)` invokes `Scope.for_user(actor)` on every resource and relationship check, triggering 5 SQL queries per check.
  3. `ScopeReadCheck` lacks filter clauses for `DnsRecord`, `TechEvidence`, `DiscoveredUrl`, `DomainTag`, and `DomainMetadata`.
* **Target Files:**
  * `lib/ravner/accounts/scope_read_check.ex`
  * `lib/ravner/inventory.ex`
  * `lib/ravner/domains.ex`
* **Implementation Details:**
  1. Update `ScopeReadCheck.filter/3` to accept pre-resolved `%Scope{}` structs directly alongside `%User{}`, and change the `nil` actor clause to `false`:
     ```elixir
     @impl true
     def filter(nil, _context, _opts), do: false

     def filter(%Scope{} = scope, %{resource: resource}, _opts) do
       if scope.global?, do: true, else: resource_filter(resource, scope)
     end

     def filter(%User{} = actor, context, opts) do
       filter(Scope.for_user(actor), context, opts)
     end
     ```
  2. Add `resource_filter/2` clauses for domain child resources:
     ```elixir
     defp resource_filter(resource, %Scope{domain_ids: ids})
          when resource in [
                 Ravner.Domains.DnsRecord,
                 Ravner.Domains.TechEvidence,
                 Ravner.Domains.DiscoveredUrl,
                 Ravner.Domains.DomainTag,
                 Ravner.Domains.DomainMetadata
               ],
          do: expr(domain_id in ^ids)
     ```
  3. In `Ravner.Inventory` and `Ravner.Domains` internal facade reads where no user actor is supplied (or where system-level preloads occur), pass `authorize?: false` explicitly (or pass `actor: scope` when `scope` is provided in `opts`).

### Task 1.3: Remove State-Changing `GET /admin/unmasquerade` Route
* **Problem:** `lib/ravner_web/router.ex` exposes `get("/admin/unmasquerade", MasqueradeController, :delete)`, allowing session mutation and WebSocket disconnection via an unauthenticated `GET` subresource request (e.g., `<img src="/admin/unmasquerade">`), bypassing CSRF protection.
* **Target Files:**
  * `lib/ravner_web/router.ex`
  * `lib/ravner_web/components/layouts/root.html.heex`
  * `test/ravner_web/controllers/masquerade_controller_test.exs`
* **Implementation Details:**
  1. Remove `get("/admin/unmasquerade", MasqueradeController, :delete)` from `RavnerWeb.Router`, retaining `post("/admin/unmasquerade", MasqueradeController, :delete)` and `delete("/admin/unmasquerade", MasqueradeController, :delete)`.
  2. Verify the masquerade banner in `root.html.heex` uses `method="post"` or `method="delete"` with CSRF token protection.

---

## 3. Phase 2: Complete Governance Auditability (`AshPaperTrail`) & Admin Forms

**Objective:** Fulfill the engineering mandate requiring `AshPaperTrail` on all compliance-relevant governance resources and `AshPhoenix.Form` on administrative UI forms.

### Task 2.1: Enable `AshPaperTrail.Resource` on `Person` and `ProjectRole`
* **Problem:** `Ravner.Inventory.Person` and `Ravner.Inventory.ProjectRole` govern organizational identity and project permission assignments (PM/PO roles) but do not record version history.
* **Target Files:**
  * `lib/ravner/inventory/person.ex`
  * `lib/ravner/inventory/project_role.ex`
* **Implementation Details:**
  Add `extensions: [AshPaperTrail.Resource]` and configure `paper_trail` blocks matching `Ravner.Inventory.Project`:
  ```elixir
  paper_trail do
    primary_key_type(:integer)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    reference_source?(false)

    belongs_to_actor :user, Ravner.Accounts.UserResource,
      domain: Ravner.Accounts.AshDomain,
      attribute_type: :integer
  end
  ```

### Task 2.2: Generate Version Table Migrations
* **Migration File:** `priv/repo/migrations/<timestamp>_add_paper_trail_to_people_and_project_roles.exs`
* **Schema Details:**
  Create `people_versions` and `project_roles_versions` tables with:
  * `id` (`bigserial`, primary key)
  * `version_action_type` (`:string`, non-null)
  * `version_action_name` (`:string`, non-null)
  * `version_source_id` (`:bigint`, non-null, indexed)
  * `changes` (`:map`)
  * `user_id` (`:bigint`, indexed)
  * `version_inserted_at` / `version_updated_at` (`:utc_datetime_usec`)

### Task 2.3: Migrate `RavnerWeb.AdminLive.Users` to `AshPhoenix.Form`
* **Problem:** `AdminLive.Users` constructs forms using raw Ecto changesets (`User.registration_changeset/3`, `User.role_changeset/2`, `User.password_changeset/3`) instead of `AshPhoenix.Form` backed by `Ravner.Accounts.UserResource`.
* **Target Files:**
  * `lib/ravner/accounts/user_resource.ex`
  * `lib/ravner_web/live/admin_live/users.ex`
* **Implementation Details:**
  1. Ensure `UserResource` exposes explicit `:admin_create`, `:admin_update`, and `:admin_reset_password` actions with password hashing and validation rules matching `Ravner.Accounts.User`.
  2. Refactor `AdminLive.Users` to initialize and submit forms via `AshPhoenix.Form.for_create/3` and `AshPhoenix.Form.for_update/3` with `actor: socket.assigns.current_scope.user`.

---

## 4. Phase 3: External Command Execution & "Stop Line" Process Isolation

**Objective:** Ensure 100% of external OS command executions route through `Ravner.SystemCommand` with timeout and process-group (`PGID`) cleanup, eliminate synchronous CLI blocking in LiveView processes, and support minimal container environments without `perl`.

### Task 3.1: Migrate `Backups` and `ApiKeys` to `Ravner.SystemCommand`
* **Problem:** `Ravner.Admin.Backups` (`pg_dump`, `pg_restore`) and `Ravner.ApiKeys` (`lonkero license status`) invoke `System.cmd/3` directly without timeouts or process-group termination.
* **Target Files:**
  * `lib/ravner/system_command.ex`
  * `lib/ravner/admin/backups.ex`
  * `lib/ravner/api_keys.ex`
* **Implementation Details:**
  1. Extend `Ravner.SystemCommand.run_with_timeout/4` options to support `env: [{String.t(), String.t()}]` passed through to `Port.open/2`.
  2. Replace `System.cmd/3` in `Ravner.Admin.Backups.safe_cmd/3` with `SystemCommand.run_with_timeout(cmd, args, 120_000, env: env)`.
  3. Replace `System.cmd/3` in `Ravner.ApiKeys` with `SystemCommand.run_with_timeout(exec, ["license", "status", "-L", key], 10_000)`.

### Task 3.2: Eliminate Synchronous OS Calls in `RavnerWeb.AdminLive.Settings`
* **Problem:** `AdminLive.Settings` executes `System.cmd("find", ...)`, `System.cmd("lonkero", ["version"])`, and `System.cmd("pa11y", ["--version"])` synchronously inside LiveView event/mount callbacks, blocking the LiveView process loop.
* **Target File:** `lib/ravner_web/live/admin_live/settings.ex`
* **Implementation Details:**
  1. Replace `System.cmd("find", [templates_path, "-name", "*.yaml", "-type", "f"])` with pure Elixir `Path.wildcard(Path.join(templates_path, "**/*.yaml"))`.
  2. Execute `lonkero` and `pa11y` version probes asynchronously via `start_async/3` calling `Ravner.SystemCommand.run_with_timeout/4` with a `5_000 ms` timeout.

### Task 3.3: Portable Process Group Isolation in `Ravner.SystemCommand`
* **Problem:** `Ravner.SystemCommand` requires `perl` (`use POSIX qw(setsid); setsid(); exec @ARGV`) to allocate a new session/process group. In minimal production container images (e.g., Alpine or slim Debian without `perl`), all external scans fail with `perl executable not found`.
* **Target File:** `lib/ravner/system_command.ex`
* **Implementation Details:**
  Implement a two-tier session leader launcher:
  1. Prefer `setsid` binary (`System.find_executable("setsid")`, standard in Linux `util-linux` / BusyBox) when available: `setsid /bin/sh -c <shell_cmd>`.
  2. Fall back to `perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV'` on macOS / BSD systems where `setsid(1)` CLI is not installed by default.

---

## 5. Phase 4: Ash/Ecto Facade Error Propagation Cleanup

**Objective:** Eliminate the double-validation anti-pattern in `execute_ash_action/5` where Ash validation failures return a valid Ecto changeset with `errors: []`.

### Task 4.1: Translate `Ash.Error` to `Ecto.Changeset` Errors
* **Problem:** In `Ravner.Domains` and `Ravner.Inventory`, `execute_ash_action/5` first checks `if fallback_changeset.valid?`. When `fallback_changeset.valid?` is `true` but the subsequent Ash action fails with an Ash-specific validation or constraint error, the function logs a warning and returns `{:error, fallback_changeset}` — which has `valid?: true` and `errors: []`, hiding the error reason from callers and UI forms.
* **Target Files:**
  * `lib/ravner/ash_error_helpers.ex` [NEW]
  * `lib/ravner/domains.ex`
  * `lib/ravner/inventory.ex`
* **Implementation Details:**
  Create `Ravner.AshErrorHelpers.to_ecto_changeset(ash_error, base_changeset)` that traverses `Ash.Error.Invalid.errors` and maps field-level and action-level errors onto `base_changeset` via `Ecto.Changeset.add_error/3`, guaranteeing `changeset.valid? == false` and non-empty `changeset.errors` on any Ash failure.

---

## 6. Phase 5: LiveView Scalability, Oban Scan Orchestration & Worker Test Suite

**Objective:** Prevent LiveView memory ballooning on large domain inventories, ensure all user-initiated batch scans respect Oban queue concurrency limits, and achieve 100% unit test coverage across Oban workers.

### Task 5.1: Migrate `RavnerWeb.DomainLive.Index` to LiveView Streams
* **Problem:** `DomainLive.Index` stores all filtered domains in `socket.assigns.domains` as a standard list and runs `Enum.map` (`replace_domain/2`) on every scan update, retaining the entire collection in BEAM process memory.
* **Target Files:**
  * `lib/ravner_web/live/domain_live/index.ex`
  * `lib/ravner_web/live/domain_live/index.html.heex`
* **Implementation Details:**
  1. Replace `assign(socket, :domains, domains)` with `stream(socket, :domains, domains, reset: true)`, tracking `@domains_count` (`length(domains)`) and `@domains_empty?` (`domains == []`) as lightweight scalar assigns.
  2. Replace `replace_domain/2` with `stream_insert(socket, :domains, updated_domain)`.
  3. Update `index.html.heex` table body to `<tbody id="domains-stream" phx-update="stream">` iterating via `:for={{dom_id, domain} <- @streams.domains} id={dom_id}`.

### Task 5.2: Route `ScanCoordinator` Subdomain Batch Scans Through Oban
* **Problem:** `RavnerWeb.DomainLive.ScanCoordinator.handle_scan_all_subdomains/1` spawns `4 * N` unthrottled `Task.Supervisor` processes that `send/2` directly to the LiveView `self()` PID. Scanning a domain with 100 subdomains spawns 400 concurrent network tasks and loses progress if the user navigates away.
* **Target Files:**
  * `lib/ravner_web/live/domain_live/scan_coordinator.ex`
  * `lib/ravner/workers/scan_worker.ex`
  * `lib/ravner/scans.ex`
* **Implementation Details:**
  1. Standardize `Ravner.Scans.run_quick_scan/1` to return `{:ok, result_map}` so `ScanWorker.finish_scan/3` handles uniform tuple contracts.
  2. Enqueue subdomain scans via `Ravner.Workers.ScanWorker.new/1` and `Oban.insert_all/1` with `notify_topic: "domain_scan:#{domain.id}"`.
  3. Subscribe `DomainLive.Show` to `"domain_scan:#{domain.id}"` via `Phoenix.PubSub` to receive `{:bulk_scan_done, subdomain_id, scan_type, status}` events safely across navigation.

### Task 5.3: Complete Oban Worker Unit Test Suite
* **Problem:** 13 of 16 Oban workers/dispatchers in `lib/ravner/workers/` lack dedicated unit tests.
* **Target Directory:** `test/ravner/workers/`
* **New Test Files:**
  1. `test/ravner/workers/a11y_scan_worker_test.exs`
  2. `test/ravner/workers/lighthouse_scan_worker_test.exs`
  3. `test/ravner/workers/heartbeat_worker_test.exs`
  4. `test/ravner/workers/heartbeat_dispatcher_test.exs`
  5. `test/ravner/workers/domain_check_dispatcher_test.exs`
  6. `test/ravner/workers/heartbeat_retention_worker_test.exs`
  7. `test/ravner/workers/uptime_notification_worker_test.exs`
  8. `test/ravner/workers/webhook_notification_worker_test.exs`
  9. `test/ravner/workers/dnsx_scan_dispatcher_test.exs`
  10. `test/ravner/workers/httpx_scan_dispatcher_test.exs`
  11. `test/ravner/workers/ssl_check_dispatcher_test.exs`
  12. `test/ravner/workers/security_scan_dispatcher_test.exs`
  13. `test/ravner/workers/a11y_and_lighthouse_dispatcher_test.exs`

---

## 7. Phase 6: Static Typing (`@spec`), Tailwind v4 Compliance & Code Hygiene

**Objective:** Satisfy strict typing mandates (`@spec` on all public context functions), remove deprecated `@apply` usage in Tailwind CSS v4, and clean up dead artifacts.

### Task 6.1: Complete `@spec` Annotations Across Public Contexts
* **Target Files & Missing Specs Count:**
  * `lib/ravner/api_keys.ex` (14 functions)
  * `lib/ravner/a11y.ex` (5 functions)
  * `lib/ravner/lighthouse.ex` (5 functions)
  * `lib/ravner/domains.ex` (14 functions)
  * `lib/ravner/inventory.ex` (14 functions)
  * `lib/ravner/accounts.ex` (7 functions)
  * `lib/ravner/uptime.ex` (6 functions)

### Task 6.2: Replace `@apply` Directives in `assets/css/app.css`
* **Problem:** `assets/css/app.css` contains 47 `@apply` directives, violating the Tailwind CSS v4 mandate in `AGENTS.md` (*"Never use `@apply` when writing raw css"*).
* **Target File:** `assets/css/app.css`
* **Implementation Details:**
  Convert all `@apply` rules inside `@layer base` and `@layer components` (`.btn-line`, `.btn-line-filled`, `.input-line`, `.card-line`, `.alert-line`, `.table-line`, `.list-line`, `.checkbox-line`, `.toast-minimal`) to standard CSS properties referencing Tailwind v4 theme variables (`var(--color-neutral-*)`, `var(--spacing)`).

### Task 6.3: Dead Code Removal, Atom Safety & Dynamic OpenAPI Version
* **Target Files:**
  * [DELETE] `lib/ravner_web/live/domain_live/form_component.html.heex` — orphaned template with no backing LiveComponent module.
  * [MODIFY] `lib/ravner/scans/dns.ex` — replace `@record_types ~w(a aaaa cname mx ns txt)` and runtime `String.to_atom/1` calls with compile-time atom list `@record_types [:a, :aaaa, :cname, :mx, :ns, :txt]`.
  * [MODIFY] `lib/ravner_web/ash_json_api_router.ex` — replace hardcoded `"0.16.0"` API version string in `modify_open_api/3` with `Application.spec(:ravner, :vsn) |> to_string()`.

---

## 8. Rollout Verification Checklist

Every phase must pass the following verification gates before merging:

- [x] `mix compile --warnings-as-errors` exits with `0` warnings.
- [x] `mix format --check-formatted` passes cleanly.
- [x] `mix credo --strict` reports zero new warnings or design violations.
- [x] `mix test` passes 100% of unit and integration tests.
- [x] `mix assets.build` compiles Tailwind v4 CSS and esbuild bundles without errors.
- [x] `mix precommit` alias succeeds end-to-end.
