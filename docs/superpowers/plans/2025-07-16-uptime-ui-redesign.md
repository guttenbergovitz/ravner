# Uptime UI/UX Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the basic uptime monitoring UI into a professional StatusCake-like experience with proper navigation hierarchy, availability visualizations (uptime bar, response time chart, daily calendar), and integrated notification management.

**Architecture:** Restructure navigation to promote Uptime to top-level tab (after Domains). Rewrite the overview page with inline uptime bars per domain. Create a rich per-domain detail page with SVG charts (hand-rolled for uptime bar/calendar, Contex for response time line chart). Move Ownership into Admin dropdown. Keep charts server-rendered SVG for zero JS deps and instant load.

**Tech Stack:** Phoenix LiveView, Tailwind CSS, SVG (hand-rolled + Contex library for line charts), Lato font.

---

## Design Principles

1. **Professional & minimal** — Lato font, neutral palette, generous whitespace
2. **Data-dense but readable** — StatusCake-inspired: uptime bars are compact visual summaries
3. **SVG-first** — No JS charting libraries. Server-rendered SVG is instant, accessible, print-friendly
4. **Dark mode aware** — All visualizations respect dark mode classes

## Navigation Restructure

**Before:**
```
Main tabs:    Dashboard | Domains | Ownership | Admin ▼
Top-right:   Users | Jobs | Uptime | Settings | Account | Logout
```

**After:**
```
Main tabs:    Dashboard | Domains | Uptime | Admin ▼
Admin ▼:      Ownership | Certificates | Registrations | Users | Jobs | Settings
Top-right:    [theme toggle] | Account | Logout
```

Reasoning:
- **Uptime** promoted to main tab — it's a daily-use monitoring view for all roles
- **Ownership** moved to Admin dropdown — it's governance/admin work, not daily operations
- Top-right decluttered — admin links consolidated into dropdown
- Uptime accessible to all authenticated users (Viewer can read, Editor/Admin can manage)

## Route Changes

```
/uptime                          → Overview (all monitored domains with uptime bars)
/uptime/:domain_id               → Per-domain detail (charts, incidents, alerts config)
/uptime/notifications            → Notification management (admin/editor)
```

Old `/admin/uptime*` routes redirected or removed.

---


## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/ravner_web/components/layouts/root.html.heex` | Modify | Nav restructure |
| `lib/ravner_web/router.ex` | Modify | Move uptime routes to authenticated scope |
| `lib/ravner/uptime.ex` | Modify | Add daily_stats/2, response_time_series/2 queries |
| `lib/ravner_web/components/uptime_components.ex` | Create | Reusable SVG chart components |
| `lib/ravner_web/live/uptime_live/index.ex` | Create | Overview page (replaces admin uptime) |
| `lib/ravner_web/live/uptime_live/index.html.heex` | Create | Overview template |
| `lib/ravner_web/live/uptime_live/show.ex` | Create | Per-domain detail |
| `lib/ravner_web/live/uptime_live/show.html.heex` | Create | Detail template with charts |
| `lib/ravner_web/live/admin_live/uptime.ex` | Delete | Replaced by uptime_live |
| `lib/ravner_web/live/admin_live/uptime.html.heex` | Delete | Replaced |
| `lib/ravner_web/live/admin_live/uptime_report.ex` | Delete | Merged into show |
| `lib/ravner_web/live/admin_live/uptime_report.html.heex` | Delete | Merged |

---


## Task 1: Add query helpers for chart data

**Files:**
- Modify: `lib/ravner/uptime.ex`

Add these functions to support the visualizations:

```elixir
@doc """
Returns daily uptime stats for a domain over N days.
Each entry: %{date: Date, uptime_percent: float, incidents: int, avg_response_ms: int | nil}
"""
def daily_stats(domain_id, days \\ 30)

@doc """
Returns response time data points for charting.
Returns list of %{at: DateTime, ms: integer} ordered by time.
"""
def response_time_series(domain_id, hours \\ 24)

@doc """
Returns uptime percentage per day for the last N days as a list of
%{date: Date, percent: float} — used for the uptime bar visualization.
"""
def uptime_bar_data(domain_id, days \\ 30)
```

- [ ] Implement `daily_stats/2` — queries heartbeat_checks grouped by date, computes uptime % and avg response time per day, counts incidents from downtime_windows
- [ ] Implement `response_time_series/2` — selects (checked_at, response_time_ms) from recent checks where response_time_ms is not null
- [ ] Implement `uptime_bar_data/2` — lightweight version of daily_stats returning just date + percent for the bar
- [ ] Verify: `mix compile --warnings-as-errors`
- [ ] Commit: `git commit -m "feat(uptime): add daily_stats, response_time_series, uptime_bar_data queries"`

---

## Task 2: Create SVG chart components

**Files:**
- Create: `lib/ravner_web/components/uptime_components.ex`

A function component module with:

### `uptime_bar(assigns)` — 30-day availability bar
- 30 vertical segments (thin rounded rectangles), one per day
- Green (#22c55e) = 100%, Yellow (#eab308) = 95-99.9%, Red (#ef4444) = <95%
- Tooltip on hover (date + %)
- Total width ~400px, height ~32px
- Accepts `@days` list of `%{date: Date, percent: float}`

### `response_chart(assigns)` — response time line chart
- Clean SVG line chart, 200px tall, full width
- Subtle grid lines (neutral-200)
- Green (#22c55e) stroke for the line, 1.5px
- Filled area below with 10% opacity green
- Y-axis: auto-scaled ms values
- X-axis: time labels (hours for 24h, dates for 7d/30d)
- Accepts `@points` list of `%{at: DateTime, ms: integer}`

### `availability_calendar(assigns)` — monthly grid
- 7-column grid (Mon-Sun), cells for each day
- Color-coded: green/yellow/red based on uptime %
- Shows month name and year
- Accepts `@days` and `@month` (Date for first of month)

- [ ] Create the component module with `uptime_bar/1`
- [ ] Add `response_chart/1` — SVG line with area fill
- [ ] Add `availability_calendar/1` — month grid
- [ ] Verify: `mix compile --warnings-as-errors`
- [ ] Commit: `git commit -m "feat(uptime): add SVG chart components (uptime bar, response chart, calendar)"`

---

## Task 3: Restructure navigation

**Files:**
- Modify: `lib/ravner_web/components/layouts/root.html.heex`

Changes:
1. Main tabs: Replace "Ownership" with "Uptime" (available to all authenticated users)
2. Move "Ownership" into the Admin dropdown menu
3. Remove admin-only top-right links (Users, Jobs, Uptime, Settings) — they move into Admin dropdown
4. Admin dropdown gets: Ownership, Certificates, Registrations, Users, Jobs, Settings
5. Keep top-right clean: just theme toggle + Account + Logout

- [ ] Restructure main nav tabs (Dashboard, Domains, Uptime)
- [ ] Expand Admin dropdown with all admin links
- [ ] Clean up top-right section
- [ ] Verify: `mix compile --warnings-as-errors`
- [ ] Commit: `git commit -m "refactor(nav): promote Uptime to main tab, consolidate Admin dropdown"`

---

## Task 4: Move uptime routes to authenticated scope

**Files:**
- Modify: `lib/ravner_web/router.ex`

Move uptime routes from admin-only scope to the general authenticated scope:

```elixir
# In the :authenticated live_session (where /domains lives):
live("/uptime", UptimeLive.Index, :index)
live("/uptime/:domain_id", UptimeLive.Show, :show)

# Keep notification management in admin scope:
live("/uptime/notifications", AdminLive.UptimeNotifications, :index)
```

Remove old `/admin/uptime`, `/admin/uptime/report`, `/admin/uptime/report/:domain_id` routes.

- [ ] Add new routes in authenticated live_session
- [ ] Remove old admin uptime routes
- [ ] Verify: `mix compile --warnings-as-errors`
- [ ] Commit: `git commit -m "refactor(routes): move uptime to authenticated scope, accessible to all roles"`

---


## Task 5: Create Uptime Overview page (StatusCake-like)

**Files:**
- Create: `lib/ravner_web/live/uptime_live/index.ex`
- Create: `lib/ravner_web/live/uptime_live/index.html.heex`

The overview shows all monitored domains with:
- Status indicator (dot: green/red/yellow)
- Domain name (link to detail)
- **Inline 30-day uptime bar** (the key visual)
- Current uptime % (last 30 days)
- Last check time
- Response time (latest)

Layout: each domain is a row/card with the uptime bar as the dominant visual element.

Summary stats at top: Total monitored, Currently up, Currently down, Average uptime %.

Auto-refresh every 15 seconds.

Link to /uptime/notifications for admin/editor.

- [ ] Create LiveView module with mount, tick, load_data
- [ ] Create template with summary cards + domain list with uptime bars
- [ ] Import uptime_components for the bar
- [ ] Verify: `mix compile --warnings-as-errors`
- [ ] Commit: `git commit -m "feat(uptime): new overview page with inline 30-day uptime bars"`

---

## Task 6: Create Per-domain Detail page

**Files:**
- Create: `lib/ravner_web/live/uptime_live/show.ex`
- Create: `lib/ravner_web/live/uptime_live/show.html.heex`

The detail page for a single domain shows:

### Header section
- Domain name, current status (big indicator), uptime % (prominent number)
- Time range selector: 24h | 7d | 30d

### Visualizations (the meat)
1. **30-day uptime bar** (larger version, full width)
2. **Response time chart** (SVG line chart, ~200px tall)
3. **Availability calendar** (monthly grid, last 1-2 months)

### Incidents section
- Table of downtime windows in selected range
- Each with: start, end, duration, notes
- Inline "add note" form for editor/admin

### Alert configuration (admin/editor only)
- "Who gets notified for this domain"
- Show current policy (per-domain or inherited from global)
- Quick link to /uptime/notifications for full management

- [ ] Create LiveView with domain loading, range switching, data fetching
- [ ] Create template with all chart sections
- [ ] Wire up note adding (reuse from old report)
- [ ] Verify: `mix compile --warnings-as-errors`
- [ ] Commit: `git commit -m "feat(uptime): per-domain detail page with charts and incidents"`

---

## Task 7: Cleanup old admin uptime pages

**Files:**
- Delete: `lib/ravner_web/live/admin_live/uptime.ex`
- Delete: `lib/ravner_web/live/admin_live/uptime.html.heex`
- Delete: `lib/ravner_web/live/admin_live/uptime_report.ex`
- Delete: `lib/ravner_web/live/admin_live/uptime_report.html.heex`

- [ ] Delete old files
- [ ] Update any remaining references (links in notifications page, etc.)
- [ ] Verify: `mix compile --warnings-as-errors`
- [ ] Run: `mix test`
- [ ] Commit: `git commit -m "refactor(uptime): remove old admin uptime pages, replaced by /uptime/*"`

---

## Task 8: Final verification

- [ ] Run `mix precommit`
- [ ] Fix any issues
- [ ] Manual check: navigation works, uptime overview loads, detail page renders charts
- [ ] Commit if needed: `git commit -m "fix(uptime): address precommit findings"`

---

## Visual Reference (StatusCake-inspired)

### Uptime bar (per domain row):
```
┌────────────────────────────────────────────────┐
│ ██ ██ ██ ██ ██ ██ ██ ██ ██ ██ ██ ██ ██ ██ ██  │  ← 30 segments
│ green green green red green green yellow ...     │  ← color by %
└────────────────────────────────────────────────┘
```

### Response time chart:
```
ms│
  │      ╭─╮
  │  ╭───╯ ╰──╮     ╭──
  │──╯        ╰─────╯
  │░░░░░░░░░░░░░░░░░░░░░  ← subtle area fill
  └─────────────────────── time
```

### Availability calendar:
```
  July 2025
  Mo Tu We Th Fr Sa Su
  ■  ■  ■  ■  ■  ■  ■   ← green = 100%
  ■  ■  ■  □  ■  ■  ■   ← red □ = <95%
  ■  ■  ■  ■  ■  ■  ■
  ■  ■  ▣  ■  ■  ...     ← yellow ▣ = 95-99.9%
```
