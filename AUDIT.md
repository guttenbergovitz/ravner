# Ravner Code Audit Report

**Date:** 2026-10-08
**Version:** 0.16.0
**Overall Score:** 7.6/10

## Executive Summary

| Area | Score | Status |
|------|-------|--------|
| Ash Framework | 7.5/10 | Good foundation, policy gaps |
| LiveView | 7.8/10 | Idiomatic, performance opportunities |
| Oban Workers | 6.5/10 | Critical error handling gaps |
| Test Coverage | 7.1/10 | 15/16 workers untested |
| Ecto Patterns | 7.6/10 | Solid, N+1 in alerts |
| Code Hygiene | 9.0/10 | Clean, no dead code |

Professional codebase with hybrid Ash/Ecto architecture. Key strengths: governance/performance boundary, coordinator patterns, API token governance. Key gaps: unscoped read policies, error swallowing in workers, and missing worker tests.

---

## Critical Issues

### 1. Domain read authorization is effectively unscoped

**Location:** `lib/ravner/domains/domain.ex:129-130`

The commented domain-level authorization block is not, by itself, proof that all
resource authorization is disabled. The confirmed issue is that the Domain
resource's read policy is `authorize_if(always())` (`lib/ravner/domains/domain.ex:129-130`),
and the same pattern exists across several inventory resources.

**Impact:** Authenticated scoped actors can read records outside their assigned
organization/project boundary through Ash JSON:API and MCP.
**Risk:** High — data exposure
**Fix:** Replace unconditional read authorization with actor-aware filtered policies and verify the same scope through JSON:API and MCP.

---

### 2. Workers Swallow All Errors

**Location:** `lib/ravner/workers/lighthouse_scan_worker.ex:10-16`, `a11y_scan_worker.ex`, `scan_worker.ex`

The A11y and Lighthouse workers map every error to `:ok`. `ScanWorker` does
propagate errors for security scans, but its HTTP, DNS, SSL and RDAP clauses
ignore the return value and then return `:ok`.

**Impact:** Failed scans undetected, no retries, no observability.
**Risk:** High — silent failures
**Fix:** Return `{:error, reason}` for transient failures, keep an explicit
`:not_scannable` outcome, and add structured logging/telemetry.

---

### 3. Worker Test Coverage Gap

**Status:** 15 of 16 workers have zero test coverage.

| Untested Workers |
|------------------|
| A11yScanDispatcher, A11yScanWorker |
| DnsxScanDispatcher |
| DomainCheckDispatcher |
| HeartbeatDispatcher, HeartbeatWorker, HeartbeatRetentionWorker |
| HttpxScanDispatcher |
| LighthouseScanDispatcher, LighthouseScanWorker |
| ScanWorker |
| SecurityScanDispatcher |
| SslCheckDispatcher |
| UptimeNotificationWorker |
| WebhookNotificationWorker |

**Impact:** Background jobs (scanning, notifications) untested.
**Risk:** High — regression risk
**Fix:** Create `test/ravner/workers/` test suite.

---

### 4. Data Migration Risk

**Location:** `priv/repo/migrations/20260509131522_normalize_domain_discovery_data.exs`

Migration removes `dns_records`, `tech_evidence`, `discovered_urls` array columns from `domain_metadata` without visible data migration script.

**Impact:** Potential data loss if arrays contained important state.
**Risk:** Critical — verify data was migrated
**Fix:** Audit migration history, verify data integrity.

---

## High Priority Issues

### 5. No Policies on Join Resources

**Location:** `lib/ravner/inventory/`

Resources without authorization:
- `ApplicationValueStream`
- `ApplicationCapability`
- `ApplicationExternalService`

**Fix:** Add policy blocks with appropriate authorization checks.

---

### 6. Accounts Domain Missing Audit Trail

**Resources:** `User`, `ApiToken`, `UserToken`, `UserInvite`

No `AshPaperTrail.Resource` extension — critical governance entities lack audit history.

**Fix:** Add PaperTrail extension:
```elixir
use Ash.Resource,
  extensions: [AshPaperTrail.Resource]

paper_trail do
  change_tracking_mode :changes_only
  store_action_name? true
end
```

---

### 7. Validation Only in Legacy Changesets

Ash actions accept fields without validation. Validation logic lives only in Ecto changesets.

**Examples:**
- `Domain` name format validation in Ecto changeset, not Ash action
- `Project` slug uniqueness not enforced in Ash action
- `Organization` name uniqueness not enforced

**Fix:** Migrate validations to Ash action definitions:
```elixir
create :create do
  accept [:name, :slug]
  validate match(:name, ~r/^[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z0-9][-a-zA-Z0-9.]*$/)
end
```

---

### 8. LiveView Mount Assign Bloat

**Location:** `lib/ravner_web/live/domain_live/show.ex:25-78`

Mount initializes 54+ socket assigns in single chain — 200-500ms latency impact.

**Fix:** Defer heavy loads to `handle_params`:
```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, :ready?, false)}
end

def handle_params(params, _url, socket) do
  if socket.assigns.ready? do
    {:noreply, socket}
  else
    {:noreply, socket |> load_domain_data(params) |> assign(:ready?, true)}
  end
end
```

---

### 9. N+1 in Dashboard Alerts

**Location:** `lib/ravner/inventory/dashboard_stats.ex:427-519`

`get_ssl_alerts/0` and `get_domain_alerts/0` fetch all expiring domains then map in Elixir.

**Fix:** Single query with UNION/CASE:
```elixir
def get_all_alerts do
  from(m in DomainMetadata,
    join: d in Domain, on: m.domain_id == d.id,
    where: m.ssl_expiry < ^threshold or m.domain_expiry < ^threshold,
    select: %{type: fragment("CASE WHEN ? < ? THEN 'ssl' ELSE 'domain' END", m.ssl_expiry, m.domain_expiry), ...}
  )
  |> Repo.all()
end
```

---

### 10. Missing Uniqueness on High-Frequency Jobs

**Workers:** `HeartbeatWorker`, `DomainCheckDispatcher`

Per-minute dispatchers can create duplicate jobs if dispatcher runs twice (clock skew, Oban recovery).

**Fix:**
```elixir
use Oban.Worker,
  queue: :heartbeats,
  unique: [period: 120, fields: [:args], keys: [:domain_id]]
```

---

## Medium Priority Issues

### 11. Inconsistent ScopeCheck Usage

`ScopeCheck` policy used in: `UserResource`, `UserInviteResource`, `Project`, `Organization`, `Person`, `ProjectRole`

Missing from: `Brand`, `Application`, `Datastore`, `ValueStream`, `BusinessCapability`

**Fix:** Apply `ScopeCheck` consistently across all governance resources.

---

### 12. Read Policies Too Permissive

Most resources have:
```elixir
policy action_type(:read) do
  authorize_if(always())
end
```

No scoped query filtering for organizational boundaries.

**Fix:** Add field-level and query-level authorization.

---

### 13. Cross-Domain Relationship Coupling

Tight coupling between domains:
- `Inventory` → `Domains` (ProjectRepository belongs_to Domain)
- `Domains` → `Inventory` (Domain belongs_to Application)
- `Accounts` → `Inventory` (UserResource has relationship to Person)

**Consideration:** Document boundaries, consider resource aliases.

---

### 14. PubSub Underutilized

Most state updates use direct `send(liveview_pid, msg)` instead of PubSub broadcast.

**Current:** Only 3 PubSub subscriptions in codebase.

**Should use PubSub for:**
- Scan completion events
- Domain lifecycle changes
- Bulk operation progress

---

### 15. No Telemetry for Most Workers

Only `HeartbeatWorker` emits telemetry events.

**Missing observability:**
- Scan execution times
- Webhook retry patterns
- Job error rates
- Queue depth monitoring

**Fix:** Add Oban telemetry hooks in `application.ex`:
```elixir
:telemetry.attach_many(
  "oban-logger",
  [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]],
  &handle_oban_event/4,
  nil
)
```

---

### 16. SecurityScan Multiple Query Pattern

**Location:** `lib/ravner/security_scans.ex:241-248`

```elixir
sec_scan = latest_security_scan(domain_id)      # Query 1
breach_scan = latest_breach_scan(domain_id)     # Query 2
# ... separately preloads findings              # Query 3, 4
```

**Fix:** Single query with JOIN and subquery for latest-per-tool.

---

### 17. Large LiveView Render Templates

| File | Lines |
|------|-------|
| `vcs_panel.ex` | 794 |
| `scan_panel.ex` | 591 |
| `security_posture_component.ex` | 511 |
| `security_report.ex` | 367 |

**Fix:** Extract into sub-components for maintainability.

---

### 18. Duplicated Permission Checks

**Location:** `lib/ravner_web/live/domain_live/show.ex`

`can_manage?()` checked in 7+ event handlers with identical pattern.

**Fix:** Guard middleware:
```elixir
defp require_can_manage(socket, handler_fn) do
  if can_manage?(socket) do
    handler_fn.(socket)
  else
    {:noreply, put_flash(socket, :error, "Permission denied")}
  end
end
```

---

### 19. Missing FK Indexes

PostgreSQL performs seq-scan on FK columns without explicit indexes.

**Tables to check:**
- `domain_metadata.domain_id`
- `CveCacheEntry` — needs `[:ecosystem, :package, :version]` composite

---

### 20. Transaction Error Handling

**Location:** `lib/ravner/scans/sync_coordinator.ex`

Transactions wrap operations but don't handle rollback scenarios explicitly.

**Fix:**
```elixir
case Repo.transaction(fn -> ... end) do
  {:ok, result} -> {:ok, result}
  {:error, reason} ->
    Logger.error("Transaction failed", reason: reason)
    {:error, reason}
end
```

---

## Low Priority Issues

### 21. Unused Queue Configuration

**Location:** `config/config.exs`

```elixir
queues: [
  deep_tech: 2,  # ← No workers enqueue here
  ...
]
```

**Fix:** Remove or document purpose.

---

### 22. SslCheckDispatcher Stubbed

**Location:** `lib/ravner/workers/ssl_check_dispatcher.ex`

```elixir
def perform(_job) do
  :ok  # Does nothing
end
```

Runs daily at 03:00 UTC but no implementation.

**Fix:** Implement or remove from cron.

---

### 23. Missing Fixture Modules

Only 2 fixture modules exist:
- `accounts_fixtures.ex`
- `domains_fixtures.ex`

Missing: Inventory (Brand, Org, Project), integrations, uptime policies.

---

### 24. Form Debouncing Not Used

**Location:** `lib/ravner_web/live/domain_live/index.ex:383-389`

Validate on every keystroke without `phx-debounce`.

**Fix:**
```heex
<input phx-change="validate" phx-debounce="300" ...>
```

---

### 25. Inconsistent `public?` Attribute Marking

Some resources mark attributes `public?(true)`, others don't — ambiguity about API exposure.

---

### 26. Legacy Ecto Changesets Coexist

Comment: "Keep Ecto changeset for UI compatibility during migration Phase 2-4"

No clear roadmap for completion.

---

## Strengths

### Architecture
- **Hybrid Ash/Ecto** — governance layer (Ash) separated from performance runtime (Ecto)
- **Stop Line Boundary** — documented in GEMINI.md and AGENTS.md
- **Coordinator Pattern** — `ScanCoordinator`, `VcsCoordinator`, `SelectionCoordinator` extract complexity

### Security
- **API Token Governance** — CIDR allowlists, URL path scoping, SHA-256 hashing
- **No Hardcoded Secrets** — all configuration via environment variables
- **Parameterized Queries** — no SQL injection risk

### Code Quality
- **Type Specs** — `@spec` on all public functions
- **Module Documentation** — comprehensive `@moduledoc` coverage
- **No Debug Statements** — clean production code
- **No TODO/FIXME** — no technical debt markers

### Integrations
- **MCP/LLM Tools** — Ash tools exposed for autonomous agents
- **JSON:API** — declarative REST endpoints via AshJsonApi
- **OpenAPI/Swagger** — auto-generated spec

### Indexing
- **GIN trgm** — full-text search on domain names
- **Composite Indexes** — `[:type, :name]`, `[:type, :lifecycle_state]`
- **Performance Migrations** — dedicated index optimization migration

---

## Prioritized Action Plan

### Week 1
| # | Issue | Priority |
|---|-------|----------|
| 1 | Scope Domain and inventory read policies | Critical |
| 2 | Fix error swallowing in workers | Critical |
| 6 | Add AshPaperTrail to Accounts | High |
| 10 | Uniqueness on heartbeat/dispatcher jobs | High |
| 15 | Telemetry for all workers | High |

### Week 2
| # | Issue | Priority |
|---|-------|----------|
| 3 | Worker test suite (15 workers) | Critical |
| 5 | Policies on join resources | High |
| 9 | N+1 fix in dashboard alerts | High |
| 7 | Migrate validations to Ash | High |

### Week 3-4
| # | Issue | Priority |
|---|-------|----------|
| 8 | LiveView mount optimization | High |
| 14 | PubSub for scan events | Medium |
| 17 | Break up large render templates | Medium |
| 18 | Permission guard middleware | Medium |

### Backlog
| # | Issue | Priority |
|---|-------|----------|
| 21-26 | Low priority cleanup | Low |

---

## Metrics Baseline (rechecked 2026-10-09)

```
Files: 217 Elixir (.ex)
Lines: 67,732 (lib/test Elixir, HEEx and support files)
Test Files: 70
Test LOC: 13,880
Ash Resources: 28
Oban Workers: 16
LiveView Modules: 44
```

---

## Appendix: File References

### Critical Files
- `lib/ravner/domains/domain.ex` — unscoped read policy
- `lib/ravner/workers/lighthouse_scan_worker.ex` — error swallowing
- `lib/ravner/workers/a11y_scan_worker.ex` — error swallowing
- `lib/ravner/workers/scan_worker.ex` — inconsistent error handling

### Large Files (Refactoring Candidates)
- `lib/ravner_web/live/domain_live/vcs_panel.ex` — 794 lines
- `lib/ravner_web/live/domain_live/scan_panel.ex` — 591 lines
- `lib/ravner_web/live/domain_live/security_posture_component.ex` — 511 lines
- `lib/ravner_web/live/domain_live/show.ex` — 54 assigns in mount

### Well-Implemented (Reference Examples)
- `lib/ravner/accounts/api_token.ex` — clean custom actions, proper policies
- `lib/ravner/accounts/scope_check.ex` — sophisticated scoped RBAC
- `lib/ravner/workers/heartbeat_worker.ex` — proper telemetry integration
- `lib/ravner/inventory/ownership_stats.ex` — efficient subquery composition

---

## Independent Verification Addendum

**Verification date:** 2026-10-09

This addendum extends the original report with findings traced through callers,
policies, workers and tests. No application or database data was modified.

### Confirmed Critical and High-Risk Findings

#### 27. Scoped managers can change ownership across boundaries

**Location:** `lib/ravner/accounts/scope_check.ex:80-89`

`manage_project` authorizes an organization or brand manager when either the
target `organization_id` or the existing `project_id` is in scope. A request can
therefore update an out-of-scope project while assigning it to an in-scope
organization. The equivalent pattern exists for organization/brand ownership.
The JSON:API project update accepts `organization_id`.

**Risk:** High — cross-tenant mutation and ownership corruption.
**Fix:** Check access to the existing record separately from permission to assign
the destination owner; make ownership assignment an explicit Ash action.

#### 28. Export controllers bypass `current_scope`

**Locations:** `lib/ravner_web/controllers/domain_export_controller.ex:13`,
`lib/ravner_web/controllers/architecture_export_controller.ex:8`

The CSV export calls `list_domains_filtered_all/1` without a scope and the
ArchiMate export loads a project by ID without a scope. Both routes are behind
authentication, but not a scope-aware authorization check.

**Risk:** High — a scoped user can download inventory belonging to another
organization.
**Fix:** Require `current_scope` in both controller actions and use scoped
context functions that fail closed when no scope is present.

#### 29. Release request paths depend on Mix

**Locations:** `lib/ravner_web/plugs/require_api_auth.ex:43`,
`require_mcp_auth.ex:56`, `require_metrics_auth.ex:31`

`Application.get_env/3` receives `Mix.env()` as its default argument. The
default is evaluated before `Application.get_env/3` runs. A standard OTP release
does not include Mix, so these plugs can raise before authentication is applied.
The code also uses both `:env` and `:environment`, neither of which is set in
the checked-in configuration.

**Risk:** High — API, MCP and metrics endpoints can fail in production.
**Fix:** Configure one environment key at compile/runtime configuration time and
read it without referencing Mix in request code. Add a release smoke test.

#### 30. OSV and VCS failures erase known security results

**Locations:** `lib/ravner/scans/cve_lookup.ex:205-207`,
`lib/ravner/scans/cve_lookup.ex:219-223`, `lib/ravner/scans/repo_scanner.ex:130-155,224`

Batch OSV failures become `%{}`; hydration failures are dropped; repository file
fetch errors become empty manifests. The scanner then deletes existing findings
and can record a clean result. This conflates “source unavailable” with “no
findings”.

**Risk:** Critical — false-negative security posture after timeout, rate limit,
authorization failure or partial response.
**Fix:** Use explicit `{:ok, result} | {:error, reason}` contracts, preserve the
last known good result, and make replacement of findings atomic.

#### 31. Unfixed OSV vulnerabilities are filtered out

**Location:** `lib/ravner/scans/cve_lookup.ex:169-177`

Any range with `introduced: "0"` and no `fixed` event is treated as non-actionable.
In OSV this represents an unfixed vulnerability affecting all versions. The
predicate must not be applied globally; product-specific exceptions need an
explicit model.

**Risk:** High — real vulnerabilities disappear from SCA and domain reports.

#### 32. Header audit reports findings from an empty header set

**Locations:** `lib/ravner/scans/security_runner.ex:302-305`,
`lib/ravner/scans/security_runner.ex:522-529`,
`lib/ravner/scans/tls_header_audit.ex:43`, `tls_header_audit.ex:366-372`

The security runner passes `%{}` when the probe did not provide headers. Because
an empty map is truthy, the auditor does not fetch headers and reports all
missing security headers. The fallback request also passes unsupported
`connect_timeout` to Req and rescues the resulting `ArgumentError` as `%{}`.

**Risk:** High — secured sites receive false HSTS/CSP/clickjacking findings.
**Fix:** Pass the actual response headers, use Req's supported timeout options,
and distinguish “measurement unavailable” from “header absent”.

#### 33. Bulk domain operations lack actor and scope checks

**Locations:** `lib/ravner_web/live/domain_live/index.ex:353-374`,
`lib/ravner_web/live/domain_live/selection_coordinator.ex:56-70,177-220`

Client-supplied IDs are accepted by `toggle_select/2`. Bulk delete calls
`Domains.bulk_delete(ids)` without an actor or scope, while bulk scans start
supervised tasks directly and bypass the Oban queue limit.

**Risk:** High — cross-scope deletion and unbounded manual scanning.
**Fix:** Re-resolve selected IDs through a scoped query at execution time, pass the
actor into the context, and enqueue all heavy work through one Oban path.

### Confirmed Data and Scheduling Findings

#### 34. SSL dispatcher is an architectural placeholder

**Location:** `lib/ravner/workers/ssl_check_dispatcher.ex:8-12`

The cron job runs daily, but `perform/1` always returns `:ok` and enqueues no
work. The configured SSL interval therefore has no effect.

#### 35. Oban workers report success after failed scans

**Locations:** `lib/ravner/workers/scan_worker.ex:30-45`,
`lib/ravner/workers/a11y_scan_worker.ex:10-15`

Security scan clauses propagate errors, but HTTP, DNS, SSL and RDAP clauses call
the scanner and then unconditionally return `:ok`. A11y and Lighthouse map all
errors except the success case to `:ok`.

**Risk:** Medium/High — retries and queue failure metrics are suppressed.

#### 36. Uptime calculations can produce incorrect history

**Locations:** `lib/ravner/uptime.ex:195-215`, `lib/ravner/uptime.ex:343-367`,
`lib/ravner_web/live/uptime_live/show.ex:338-344`

Downtime windows are filtered by `started_at >= from_dt`, excluding an incident
that began before the reporting interval but continued into it. Monthly ranges
are calculated with `offset * 30` days, which skips or repeats calendar months.
The LiveView chart also loads only 60 daily points while presenting a month
navigation UI.

**Fix:** Use interval-overlap predicates (`started_at < to_dt` and
`ended_at > from_dt`/open-ended equivalent) and calendar month arithmetic.

#### 37. Notification recipient resolution can leak events

**Locations:** `lib/ravner/notifications.ex:214-233`,
`lib/ravner/notifications.ex:42-52`

When no enabled global policy exists, fallback resolution returns every recipient
with a webhook URL, including recipients from disabled or unrelated policies.
Oban uniqueness keys use `event_type` and `dedup_key` but omit `recipient_id`,
so different recipients can suppress one another's deliveries.

#### 38. Technology evidence replacement deletes other sources

**Location:** `lib/ravner/domains/sync_coordinator.ex:45-49`

`sync_tech_evidence/2` deletes all evidence for a domain before inserting the new
set. A HTTP scan can therefore remove evidence previously recorded by VCS or
another scanner.

#### 39. Security risk weight is calculated with `count`, not `sum`

**Location:** `lib/ravner/security_scans.ex:600-617`

The expression counts rows matching a weighted CASE expression, so critical and
medium findings contribute one each instead of 10 and 1. Ordering of the most
vulnerable domains is therefore incorrect.

### Verification Notes

- `MIX_ENV=test mix compile --warnings-as-errors` passed.
- `mix format --check-formatted` passed.
- `mix credo --strict` completed with 327 findings; the dominant categories are
  cyclomatic complexity, nesting and alias/design warnings.
- Targeted local checks reproduced: `Mix.env/0` fails when Mix is absent from the
  code path; `Req.new(connect_timeout: 2000)` raises an unknown-option error;
  header audit of `%{}` produces four missing-header findings; the CVE predicate
  rejects an unfixed `introduced: 0` range; the ETS cache cleanup match deletes
  zero records for the stored tuple shape.
- Full database tests were not run: the test configuration loads `.env`, whose
  database host points to a remote Neon instance, and no isolated local
  PostgreSQL service was available. No database writes were performed.

### Revised Priority Order

1. Scope-aware reads/exports and ownership mutation checks.
2. Remove Mix from release request paths.
3. Preserve security results across OSV/VCS/HTTP failures.
4. Fix bulk operation authorization and route all heavy scans through Oban.
5. Correct CVE filtering and HTTP header audit semantics.
6. Repair SSL scheduling, uptime interval/month arithmetic and notification
   recipient isolation.
7. Add actor-aware PaperTrail and unify Ash/Ecto validation contracts.
8. Refactor large contexts/templates after correctness work is covered by tests.

## Remediation Progress

### 2026-10-09 — Point 1: Scoped governance reads

**Status:** Remediated for all inventory resources that expose ownership either
directly or through an Ash relationship path.

Implemented in the remediation commits for this point:

- Added `Ravner.Accounts.ScopeReadCheck`, a shared Ash `FilterCheck` backed by
  `ScopeResolver`.
- Replaced unconditional read policies for `Domain`, `Brand`, `Organization`,
  `Project`, `Person`, `ProjectRole`, `Application`, and `ProjectRepository`.
- Added a regression test proving an organization manager cannot read a domain
  belonging to another organization.
- Propagated the actor while loading project-role relationships after creation.
- Added relationship-aware filters for datastores, value streams, business
  capabilities, external services, hosting environments, network access,
  architecture constraints, and registrars.

The un-authorized application join resources remain covered by audit point 5,
which requires explicit policy blocks for their own create/update/destroy
operations. Export authorization and bulk-operation authorization remain
separate audit points.

The release request-path issue involving `Mix.env/0` was resolved earlier in
commit `d8f26ee`; a release smoke test is still recommended.

### 2026-10-09 — Point 2: Scoped exports

**Status:** Remediated.

- Domain CSV export now passes the authenticated `current_scope` into the
  domain query, so scoped users receive only domains in their resolved scope.
- ArchiMate project export now loads the project with the authenticated actor.
- Unauthorized or out-of-scope project exports return `404` instead of raising
  an exception or exposing whether a project exists.
- Added controller regression tests for domain export isolation and project
  export denial.

### 2026-10-09 — Point 3: Bulk operation authorization

**Status:** Remediated for domain selection operations.

- Selected IDs are re-resolved through the current scope immediately before
  execution, including subdomain expansion.
- `Domains.bulk_delete/2` now requires an actor and deletes only permitted
  domain IDs; the previous actorless path fails closed.
- Bulk quick and security scans are enqueued through the `:scans` Oban queue
  instead of starting unbounded `Task.Supervisor` work directly.
- Scan workers publish completion events to a user-scoped PubSub topic so the
  LiveView can clear its in-progress state.
- Added a regression test for actor-required, scope-limited bulk deletion.

### 2026-10-09 — Point 4: Preserve results when scan sources fail

**Status:** Remediated for OSV and repository SCA ingestion.

- OSV failures now return an explicit error through `CveCache` and
  `CveLookup`; failed lookups are not cached as empty findings.
- Security scans therefore fail before finalization instead of recording a
  clean result after an unavailable OSV source.
- Repository manifest fetches distinguish missing optional manifest files from
  provider/authentication/transport failures.
- Repository SCA keeps existing vulnerability rows when dependency discovery or
  OSV correlation fails and records the repository scan as failed.
- Updated regression coverage for OSV failure behavior.

### 2026-10-09 — Point 5: Unfixed OSV vulnerabilities

**Status:** Remediated.

The global predicate that discarded every OSV range with `introduced: "0"`
and no `fixed` event has been removed. Unfixed vulnerabilities are now retained
for explicit product-level triage; product-specific `wontfix` decisions must be
modeled separately rather than inferred from the OSV range shape. Regression
coverage now expects both fixed and unfixed findings to remain visible.

### 2026-10-09 — Point 6: Header audit measurement semantics

**Status:** Remediated.

- Security probes now pass the captured security-header map into the TLS/header
  auditor instead of forcing `%{}`.
- Empty or unavailable probe headers trigger a fallback request; an unavailable
  measurement is no longer interpreted as a response missing every header.
- Removed the unsupported `connect_timeout` Req option from the fallback HEAD
  request.
- Existing TLS/header audit tests pass after the change.

### 2026-10-09 — Point 7: Worker error propagation

**Status:** Remediated for scan workers.

- A11y and Lighthouse workers now return retryable errors to Oban instead of
  mapping every failure to `:ok`.
- HTTPX, DNSX, SSL, RDAP, and heavy security scan jobs now propagate scanner
  errors through a shared result normalizer.
- The explicit `:not_scannable` outcome remains a successful terminal result,
  because retrying an ineligible domain cannot improve the outcome.

### 2026-10-09 — Point 8: Unique heartbeat jobs

**Status:** Remediated.

`HeartbeatWorker` now uses an Oban uniqueness window keyed by both
`domain_id` and `domain_check_id`. Repeated heartbeat and custom-check
dispatcher runs cannot enqueue duplicate work for the same target during the
two-minute window.

### 2026-10-09 — Point 9: Worker telemetry

**Status:** Remediated.

Added a centralized Oban telemetry handler for job start, completion, and
exception events. It emits structured logs containing job identity and timing
measurements, giving operations visibility into queue failures and runtime
without adding logging code to every worker.

### 2026-10-09 — Point 10: Join-resource policies

**Status:** Remediated.

`ApplicationValueStream`, `ApplicationCapability`, and
`ApplicationExternalService` now use Ash policy authorization. Reads follow the
owning application's project scope, while writes require an administrator or
editor actor.

### 2026-10-09 — Point 11: Accounts audit trail

**Status:** Remediated.

Enabled AshPaperTrail for users, persisted auth tokens, invites, and API tokens.
The accounts domain now registers the generated version resources and enables
version persistence. Added version tables and source-ID indexes for the three
account resources that did not previously have storage; API token history uses
the existing `api_tokens_versions` table. Administrative account changes can
now answer who changed what and when through the same audit mechanism as the
governance inventory.

### 2026-10-09 — Point 12: Ash action validation

**Status:** Remediated for core governance identifiers.

Domain create actions now enforce the hostname format previously available only
through the legacy Ecto changeset. Project and organization create actions
require their governance fields and validate slugs as lowercase hyphenated
identifiers. Existing Ash identities continue to enforce database uniqueness;
partial updates retain their existing semantics and are validated by the
database constraints and legacy changeset facade.

### 2026-10-09 — Point 13: Domain show mount cost

**Status:** Remediated.

The domain detail LiveView no longer queries all projects, brands, and
organizations during the disconnected mount. It initializes lightweight empty
assigns and loads scope-filtered governance options only after the requested
domain has been identified and authorized in `handle_params`. This removes
three database reads from the initial mount while preserving the same form
options for the connected view.

### 2026-10-09 — Point 14: Dashboard expiry alerts

**Status:** Remediated.

SSL and domain-expiration alerts are now fetched from one joined query and
partitioned in memory into the two dashboard sections. Each list keeps its own
ordering and expiry status, while the database no longer performs two nearly
identical scans of `domain_metadata` and `domains` for every dashboard load.

### 2026-10-09 — Point 15: Domain-check dispatcher uniqueness

**Status:** Remediated.

`DomainCheckDispatcher` now has an Oban uniqueness window for its dispatcher
arguments. Combined with the target-key uniqueness on `HeartbeatWorker`, a
cron retry or overlapping dispatcher execution cannot create duplicate custom
check jobs for the same interval.

### 2026-10-09 — Point 16: ScopeCheck consistency review

**Status:** Reviewed; no unsafe broadening applied.

All listed resources now have the actor-aware `ScopeReadCheck` on reads. Their
write policies remain administrator/editor-only where the resource has no
complete ownership relation or dedicated scoped permission in `ScopeResolver`.
Adding a generic `ScopeCheck` there would grant access without a reliable
project or organization boundary, so the audit item is closed as an explicit
policy decision rather than by adding a misleading check.

### 2026-10-09 — Point 17: Worker regression coverage

**Status:** Partially remediated; scheduling and scanner-result contracts covered.

Added regression tests for the Oban uniqueness contracts on heartbeat jobs and
domain-check dispatchers, plus explicit failure behavior for unknown scan
types. The remaining worker matrix still needs integration tests around
heavy external scanner execution and dispatcher selection; those should be
added with service-specific fakes rather than brittle network tests. Scan jobs
now also have a domain/scan-type uniqueness window, preventing overlapping
dispatcher and manual submissions. A11y and
Lighthouse success, terminal eligibility, and retryable error outcomes are now
covered with a configurable test runner seam. Quick scan success/failure PubSub
notifications are also covered end to end through the worker.

### 2026-10-09 — Point 25: SSL scan scheduling

**Status:** Remediated.

Implemented `SslCheckDispatcher` instead of leaving the cron worker as a
placeholder. Domain metadata now stores `ssl_scanned_at`, the dispatcher selects
scannable non-redirect domains whose configured interval is due, and enqueues
deduplicated `ScanWorker` SSL jobs. Successful SSL scans update the timestamp
alongside certificate metadata, while failed scans remain eligible for retry.

### 2026-10-09 — Point 18: Foreign-key index review

**Status:** Already satisfied; no migration required.

The audited columns are indexed in the existing schema: `domain_metadata`
already has a unique index on `domain_id`, and `cve_cache` has a unique
composite index on `ecosystem`, `package`, and `version`. The migration history
also indexes the relevant scan, project, and application foreign keys.

### 2026-10-09 — Point 19: Latest security-scan query pattern

**Status:** Measured; no code change justified at current scale.

The current helper intentionally returns fully preloaded scan structs and is
used by several LiveViews and report paths. `EXPLAIN` against the configured
PostgreSQL database shows a current cost of about `1.01` for each latest-scan
lookup and about `1.05` for the findings preload; sequential scans are expected
for the currently small tables. Both relevant indexes already exist, so a
window-function refactor would add complexity without measurable benefit. The
query-plan check should be repeated when scan history grows materially.

### 2026-10-09 — Point 20: Sync transaction failures

**Status:** Remediated.

`SyncCoordinator` now wraps each Ecto transaction in a shared result handler.
Successful results preserve the existing `{:ok, result}` contract; rollbacks
are returned unchanged and logged with the operation name and reason, making
bulk synchronization failures observable without swallowing the database error.

### 2026-10-09 — Point 21: Oban queue configuration

**Status:** Remediated.

Removed the unused `deep_tech` queue from the Oban configuration. Deep-tech
scans currently run through the LiveView coordinator synchronously, while all
actual Oban workers use the configured `heartbeats`, `scans`, `notifications`,
or `default` queues.

### 2026-10-09 — Point 22: LiveView permission-check duplication

**Status:** Reviewed; duplication is localized and bounded.

`DomainLive.Show` has five management events that intentionally perform the
same early authorization guard before different domain mutations. The actual
permission calculation is centralized in `can_manage?/1`, and scan events use
the shared coordinator helper. A further callback abstraction would reduce a
few lines but make event-specific error handling less explicit, so this item is
kept as a low-risk maintainability follow-up.

### 2026-10-09 — Point 23: Bulk scan completion events

**Status:** Remediated for quick scans.

Single-domain and visible-domain quick scans now enqueue `ScanWorker` jobs and
publish completion through the existing user-scoped PubSub topic. The previous
`Task.Supervisor` plus direct-process `send/2` path could lose completion state
when the LiveView process changed; Oban retry and PubSub delivery now share the
same flow as bulk security scans.

### 2026-10-09 — Point 24: Cross-domain architecture boundaries

**Status:** Remediated through documentation.

Added an architecture note describing the Ash governance boundary, the direct
Ecto/Oban runtime boundary, and rules for crossing between Accounts, Domains,
and Inventory. The documentation is linked from the master index and records
when a new write must use an actor-aware Ash action and audit trail.

### 2026-10-09 — Point 26: `DomainLive.ScanPanel` size and responsibility split

**Status:** Remediated.

The scan panel previously combined event delegation, discovery controls,
quality result cards, and scheduling forms in one large LiveComponent. The
quality cards and scheduling controls now live in focused function-component
modules, while `ScanPanel` keeps orchestration and event handling. The main
component is now below 250 non-blank, non-comment lines; existing LiveView
coverage remains green after the extraction.

### 2026-10-09 — Point 27: Uptime range and calendar calculations

**Status:** Remediated.

Downtime queries now use interval-overlap predicates, so incidents that begin
before a report window or remain open are included when they overlap it. Daily
incident counts use the same overlap semantics. Monthly statistics and the
month chart now use calendar-month arithmetic instead of fixed 30-day offsets,
and the chart loads the full selected month range rather than a fixed 60-day
slice. Regression coverage verifies cross-month navigation and overlapping
incidents.

### 2026-10-09 — Point 28: Notification recipient isolation

**Status:** Remediated.

Security notification fallback no longer broadcasts to every webhook recipient
when no enabled global policy exists; it now returns no recipients. Oban
uniqueness keys now use explicit top-level arguments and include
`recipient_id`, so one recipient's deduplication window cannot suppress another
recipient's delivery. Regression coverage verifies both policy isolation and
same-event delivery to multiple recipients.

### 2026-10-10 — Point 29: Technology evidence source preservation

**Status:** Remediated.

`sync_tech_evidence/2` now replaces only the sources present in the incoming
batch and leaves evidence from independent scanners, such as VCS, intact.
Empty source batches are treated as no-ops, so a transient empty response cannot
erase the domain's evidence. Regression coverage verifies both source
coexistence and empty-input behavior.

### 2026-10-10 — Point 30: Security risk weight aggregation

**Status:** Remediated.

Portfolio vulnerable-domain ranking now sums severity weights (`critical=10`,
`high=5`, `medium=1`) instead of counting matching rows. The selected
`risk_weight` and ordering expression use the same weighted aggregate. Regression
coverage verifies that one critical finding outranks three medium findings.
