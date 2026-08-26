# Uptime Monitoring & Alerting System

## Problem

Ravner has a working heartbeat mechanism (dispatcher checks overdue domains every minute, worker pings and overwrites `is_up` + `last_heartbeat_at`), but it is fire-and-forget with no history, no incident detection, no notifications, and no dedicated status view. We need a StatusCake-like uptime monitoring system with history, alerts (email + SMS), a dedicated status tab, and governance-ready reporting.

## Current State

| Component | Location | What it does |
|-----------|----------|--------------|
| `HeartbeatDispatcher` | `lib/ravner/workers/heartbeat_dispatcher.ex` | Oban cron every minute — queries domains where `last_heartbeat_at + interval < NOW()`, enqueues workers |
| `HeartbeatWorker` | `lib/ravner/workers/heartbeat_worker.ex` | HTTP ping via `httpx` — overwrites `domain_metadata.is_up` + `last_heartbeat_at` |
| Per-domain config | `domain_metadata.heartbeat_interval_minutes` | Configurable interval per domain (null = disabled). Set in domain panel, visible in `/admin/jobs` |
| Swoosh mailer | `lib/ravner/mailer.ex`, `config/config.exs` | Configured (Local in dev, SMTP env in prod). Used by `UserNotifier` |
| Roles | Router pipelines | `:require_admin`, `:require_editor` — Admin/Editor/Viewer model in place |

**Does NOT exist:** heartbeat result history, downtime windows, incident detection, status change notifications, SMS delivery, dedicated uptime status tab, uptime reports, governance notes.

## Target Architecture

### 1. Heartbeat History & Downtime Detection

#### Table: `heartbeat_checks`

| Column | Type | Notes |
|--------|------|-------|
| `id` | bigint PK | |
| `domain_id` | integer FK | references domains |
| `checked_at` | utc_datetime | timestamp of check |
| `is_up` | boolean | result |
| `response_time_ms` | integer | nullable, measured elapsed or parsed from output |
| `error_reason` | string | nullable, category of failure |

Index: `(domain_id, checked_at DESC)` for fast per-domain queries.

#### Modification to `HeartbeatWorker`

- Continue updating `domain_metadata.is_up` + `last_heartbeat_at` (backward compatibility).
- Additionally INSERT into `heartbeat_checks`.
- Measure response time where possible.

#### Downtime Detection Logic

On each heartbeat check, after persisting the result:
1. Count consecutive failures for the domain (latest N checks).
2. If consecutive failures >= threshold AND no open downtime window exists → open a `DowntimeWindow`.
3. If check is successful AND an open downtime window exists → close it (set `ended_at`, compute duration).

Threshold is configurable per domain (default: 2 consecutive failures).

#### Table: `downtime_windows`

| Column | Type | Notes |
|--------|------|-------|
| `id` | bigint PK | |
| `domain_id` | integer FK | |
| `started_at` | utc_datetime | first failure that opened the window |
| `ended_at` | utc_datetime | nullable (null = still down) |
| `duration_seconds` | integer | computed on close |
| `failure_threshold_used` | integer | threshold value at time of detection |

#### Data Retention

- Raw `heartbeat_checks` retained for X days (default 90, configurable). Pruned by periodic Oban job.
- `downtime_windows` retained indefinitely (lightweight records with governance value).

### 2. Dedicated Uptime Tab (StatusCake-like)

**Route:** `/admin/uptime` — separate tab in admin navigation.

#### Status View

- Lists all domains with active heartbeat monitoring (`heartbeat_interval_minutes` is not null).
- Per domain row: domain name, current state (Up / Down / Degraded), last check time, response time, configured interval, next expected check.
- Real-time updates via LiveView.
- Filters: All / Down only / by project / by organization.
- Minimum granularity: 1 minute (interval per domain >= 1).

#### Report View

- Time range selector: 24h, 7d, 30d, custom range.
- Per domain: uptime %, incident count, total downtime.
- List of downtime windows (start, end, duration) with link to detail.
- Detail view: heartbeat timeline within the window, governance notes.

### 3. Notification System

#### Notification Policies — Three Levels

| Level | Description | Priority |
|-------|-------------|----------|
| **Global** | Default policy for all monitored domains | Lowest |
| **Group** | Named notification group (e.g. "Platform Team") assignable to multiple domains | Medium |
| **Per domain** | Override for a specific domain | Highest (wins) |

**Resolution logic:** per-domain policy > group > global fallback. If a domain has its own policy, only that fires. If not, check assigned groups. If none, fall back to global.

#### Recipients

A recipient is either:
- **System user** — reference to `users` table. Notification goes to user's email (+ phone if set in profile).
- **Manual entry** — ad-hoc email address and/or phone number for external stakeholders without system accounts.

Each recipient has configured channels: email only, SMS only, or both.

#### Email Channel

- Uses existing Swoosh mailer infrastructure.
- Dedicated branded template for uptime notifications (incident open, incident resolved, "still down" reminder).
- **Configurable mailer identity per app:** admin sets from-address, display name, reply-to, subject prefix for uptime notifications (separate from other system emails if desired).

#### SMS Channel — Configurable Provider

**Behaviour:** `Ravner.Notifications.SmsAdapter`

```elixir
@callback send_sms(to :: String.t(), body :: String.t(), opts :: keyword()) ::
  {:ok, reference_id :: String.t()} | {:error, reason :: term()}
```

**Built-in adapters:**
- `Twilio`
- `Log` — dev/test adapter (logs to console)

**Admin configuration:**
- Admin selects active provider from available adapters in `/admin/settings`.
- Per-provider config fields (region, sender ID, etc.) — credentials stored in env/secrets, not DB.
- Test send button to verify configuration.

#### Notification Triggers

- **Incident open** — downtime window created → notify recipients.
- **Incident resolved** — downtime window closed → notify recipients.
- **Still down reminder** — configurable interval (e.g. every 30 min), max N reminders per incident.

#### Idempotency

- Table `notification_deliveries`: tracks (downtime_window_id, recipient_id, event_type). Max one delivery per combination.
- "Still down" reminders tracked with sequence number.
- No duplicate alerts for the same incident.

### 4. Governance Notes (Downtime Annotations)

- Attached to a `DowntimeWindow` record.
- Fields: author (user reference), content (text), created_at, updated_at.
- Multiple notes per downtime window (timeline of updates — root cause, mitigation, follow-up).
- Visible in report detail view.
- Editor/Admin can create/edit; Viewer can read.

### 5. RBAC

| Role | Status tab | Reports | Monitor config | Notes | Notification groups | SMS provider |
|------|------------|---------|----------------|-------|---------------------|--------------|
| Viewer | read | read | — | read | — | — |
| Editor | read | read | manage | CRUD | manage | — |
| Admin | read | read | manage | CRUD | manage | configure |

## Implementation Phases

### Phase 1 — History + Downtime Detection

- [ ] Migration: `heartbeat_checks` table
- [ ] Migration: `downtime_windows` table
- [ ] Modify `HeartbeatWorker`: persist check result + detect state flip
- [ ] Downtime open/close logic with configurable threshold
- [ ] Oban job: retention (prune old heartbeat_checks)

### Phase 2 — Status Tab (UI)

- [ ] LiveView at `/admin/uptime` — monitored domains with real-time status
- [ ] Filters, sorting, color-coded state indicators
- [ ] Add to admin navigation

### Phase 3 — Notification System

- [ ] Schema: `notification_policies`, `notification_groups`, `notification_recipients`
- [ ] `SmsAdapter` behaviour + adapters (Twilio, Log)
- [ ] Configurable mailer identity for uptime emails (from/display name/reply-to)
- [ ] Notification dispatcher (Oban worker triggered on state flip)
- [ ] Idempotency tracking (`notification_deliveries`)
- [ ] "Still down" reminders
- [ ] Admin UI: provider selection, group management, global policy config, per-domain policy

### Phase 4 — Reports + Notes

- [ ] Report view: time range selector, uptime %, downtime list per domain
- [ ] Downtime detail view with heartbeat timeline
- [ ] Governance notes CRUD on downtime windows
- [ ] Export (CSV) — nice-to-have

## Acceptance Criteria

1. Domains with `heartbeat_interval_minutes` set have heartbeat results persisted with full history.
2. Minimum monitoring granularity is 1 minute (interval per domain >= 1).
3. Downtime windows are created automatically after N consecutive failures (configurable threshold, default 2).
4. A dedicated uptime tab exists in admin — StatusCake-like real-time status view.
5. Uptime report can be generated for any time range showing uptime %, incident count, and downtime list per domain.
6. Email notifications fire on incident open/resolved using a branded template with configurable sender identity.
7. SMS notifications fire on incident open/resolved via a configurable provider (Twilio / Log) selectable in admin.
8. Recipients can be system users or manually entered contacts (email and/or phone number).
9. Notification policy resolution: per-domain > group > global.
10. Notifications are idempotent — no duplicates per incident per recipient.
11. Governance notes can be attached to downtime windows and are visible in reports.
12. RBAC enforced: Viewer read-only, Editor manages monitors/notes/groups, Admin configures providers and global policy.
