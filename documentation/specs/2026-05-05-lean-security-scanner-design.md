# Lean Security Scanner & Composed Domain View

**Date:** 2026-05-05
**Status:** Implemented

## Problem

The current security scanner is bloated and poorly composed with the rest of the
domain page:

- Four parallel entry points (`run_naabu_scan`, `run_nuclei_scan`,
  `run_httpx_binary_scan`, `run_deep_scan`) producing four kinds of
  `SecurityScan` records, individually triggerable from "Advanced Tools".
- Security Posture renders a stream of historical scans — multiple `httpx`
  cards, lone `naabu`, lone `nuclei` — with no signal about which one
  represents the current state of the domain.
- Naabu findings carry severity `"info"`, but the scan-card UI only counts
  `critical/high/medium/low`, so naabu always renders as "0 / 0 / 0 / 0 — No
  vulnerabilities found", which is misleading for port discovery.
- Open ports are not surfaced anywhere on the domain page beyond raw scan
  findings.
- Nuclei is run against every port discovered by naabu (up to 100), routinely
  exhausts the timeout, and floods Security Posture with `failed` records.
- `tech_stack` is only synced from the deep scan; standalone scans don't enrich
  the domain.

## Goal

Replace the four-mode scanner with a single lean **Security Scan** that:

1. Runs httpx → naabu → a tightly-scoped nuclei pass, completing in minutes.
2. Persists meaningful results back into `domain_metadata` so they compose with
   the rest of the domain page.
3. Surfaces only the **latest** scan's status on the domain page (no history
   list, no per-tool cards).

## Scope

### In scope

- New single scan mode (`tool: "security_scan"`).
- Lightweight nuclei: `-severity critical,high`, only against `domain:80` and
  `domain:443`.
- Migration adding `open_ports` and `last_security_scan_at` to
  `domain_metadata`.
- Upserting `tech_stack`, `open_ports`, `http_status`, `final_url`,
  `server_header`, `hosting_platform`, `last_security_scan_at` after each
  successful scan.
- Replacing the Security Posture stream with a single "latest scan" card.
- Severity badge row near the top of the domain page, derived from the latest
  completed scan.
- Open ports rendered as chips inside the Infrastructure section.
- Removing all standalone scan entry points, handlers, and the "Advanced
  Tools" UI block.

### Out of scope

- Filtering the domain listing by open ports / severity.
- Caching severity counts on `domain_metadata` (computed on read).
- Mapping port → service name (e.g. 22 → "ssh"); chips show numbers only.
- A separate scan-history view (the `SecurityScan` rows still exist in the
  database; only the UI surface is trimmed).
- Refactoring the runner into a generic pipeline abstraction; with one mode
  the existing inline phases stay readable.

## Design

### Schema

Migration `add_lean_scanner_fields_to_domain_metadata`:

```elixir
alter table(:domain_metadata) do
  add :open_ports, {:array, :integer}, default: []
  add :last_security_scan_at, :utc_datetime
end
```

`Ravner.Domains.DomainMetadata`:

- Add the two new fields to the schema and to the `cast/2` allow-list.
- Defaults match the migration (empty array, nil).

### Scanner — `Ravner.Scans.SecurityRunner`

**Removed (dead code after this change):**

- `run_naabu_scan/2`, `run_nuclei_scan/2`, `run_httpx_binary_scan/2`
- `do_naabu_scan/3`, `do_nuclei_scan/3`, `do_httpx_binary_scan/3`

**Renamed:**

- `run_deep_scan/2` → `run_security_scan/2`
- `do_deep_scan/3` → `do_security_scan/3`
- Tool name written to `SecurityScan.tool`: `"security_scan"`.
  Update the inclusion validation in
  `Ravner.SecurityScans.SecurityScan.changeset/2` accordingly.

**Lightweight nuclei (inside `do_security_scan/3`):**

After naabu finishes, drop the `domain:port` target file. Run nuclei with:

```
nuclei -u <domain> -tags http,ssl,exposure
       -severity critical,high -jsonl -silent -timeout 10
       -disable-update-check -no-stdin -c 50 -bulk-size 25 -rl 200
```

Two implicit targets (`http(s)://domain`); nuclei picks scheme based on
templates. The temp-file pattern is no longer needed.

`@deep_scan_nuclei_timeout` reduced from `480_000` (8 min) to `240_000` (4
min) — the surface area is two URLs, not 100.

**Post-scan upsert (in `finalize_scan/6` for `:security_scan` only):**

Build a `metadata_attrs` map from the captured httpx + naabu output, dropping
keys with `nil` or empty values:

```elixir
%{
  open_ports: ports_from_naabu,
  tech_stack: tech_from_httpx,
  http_status: status_from_httpx,
  final_url: final_url_from_httpx,
  server_header: server_from_httpx,
  hosting_platform: cdn_from_httpx,
  last_security_scan_at: DateTime.utc_now()
}
```

Call `Ravner.Domains.upsert_domain_metadata/2` with the filtered map. Existing
values from other scanners (DNS, RDAP, manual) are preserved when the security
scan can't determine them.

The existing `sync_tech_stack/2` helper is folded into this single upsert —
remove the standalone function.

### Context — `Ravner.SecurityScans`

**New helper:**

```elixir
@spec severity_counts_for_domain(integer()) ::
        %{critical: non_neg_integer(), high: non_neg_integer(),
          medium: non_neg_integer(), low: non_neg_integer()}
def severity_counts_for_domain(domain_id)
```

Looks up the most recent `completed` scan for the domain (any tool, but in
practice always `security_scan`) and groups its findings by severity. Returns
zeros when there is no completed scan.

**`prune_old_scans/1`** (existing) keeps the latest N completed scans per
domain. With one tool, the cap can stay at the existing value (currently 5)
or be reduced to 3 — implementation choice; not a hard requirement.

### LiveView — `RavnerWeb.DomainLive.Show`

**Removed:**

- `handle_event("scan_naabu", ...)`, `handle_event("scan_nuclei", ...)`,
  `handle_event("scan_httpx_binary", ...)`.
- The `:security_scans` stream and any handle_info that fans out per-tool.
  The single completed scan is loaded into a regular assign.

**New / changed:**

- `handle_event("run_security_scan", ...)` → calls
  `SecurityRunner.run_security_scan/2`.
- On mount and after each `{:scan_done, ...}`:
  - `assign(:latest_security_scan, SecurityScans.latest_completed_scan(domain_id))`
  - `assign(:severity_counts, SecurityScans.severity_counts_for_domain(domain_id))`
  - `assign(:running_security_scan, SecurityScans.running_scan(domain_id))` (or `nil`)

### Template — `lib/ravner_web/live/domain_live/show.html.heex`

**Severity badge row (top of page, near domain name / lifecycle):**

```heex
<div class="flex gap-1.5 items-center">
  <%= for {sev, count, color} <- severity_badges(@severity_counts) do %>
    <span class={["text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded-sm",
                  if(count > 0, do: color, else: "bg-neutral-50 text-neutral-300")]}>
      {count} {sev}
    </span>
  <% end %>
</div>
```

`severity_badges/1` returns a fixed-order list `[{"critical", n, "..."},
{"high", n, "..."}, {"medium", n, "..."}, {"low", n, "..."}]`. Zero counts
render greyed out so the row stays consistent across domains.

**Open ports in Infrastructure section** (under tech_stack):

```heex
<%= if @domain.domain_metadata && @domain.domain_metadata.open_ports != [] do %>
  <div class="mt-4">
    <p class="text-[10px] uppercase tracking-widest text-neutral-400 mb-1.5">Open Ports</p>
    <div class="flex flex-wrap gap-1">
      <%= for port <- @domain.domain_metadata.open_ports do %>
        <span class="text-[11px] font-mono px-1.5 py-0.5 border border-neutral-200 text-neutral-600 rounded-sm">
          {port}
        </span>
      <% end %>
    </div>
  </div>
<% end %>
```

**Security Posture section, full rewrite:**

- Header with domain name (already exists) + a single "Run Security Scan"
  button.
- If `@running_security_scan`: progress bar with phase label
  (Tech Detection / Port Discovery / Vulnerability Scan / Finalizing) — same
  visual as today.
- Else if `@latest_security_scan`:
  - Status row: "Last scan completed YYYY-MM-DD HH:MM" + a "Run Security
    Scan" button.
  - Findings list (same look as today's completed-card) — top 15 by severity.
  - "View {N} more findings" link if applicable.
  - Failure card with `error_message` and admin "Delete" button when status
    is `"failed"`.
- Else (no scan ever): empty state — "No security scan yet" + "Run Security
  Scan" button.

**Removed:**

- The whole `phx-update="stream"` loop over `@streams.security_scans`.
- The "Advanced Tools" `<details>` block.

## Data flow

```diagram
          User
           │ click "Run Security Scan"
           ▼
╭───────────────────────────╮
│ DomainLive.Show           │
│ handle_event              │
╰─────────────┬─────────────╯
              │
              ▼
╭─────────────────────────────────────────╮
│ SecurityRunner.run_security_scan/2      │
│   ┌────────┐  ┌───────┐  ┌────────────┐ │
│   │ httpx  │─▶│ naabu │─▶│ nuclei     │ │
│   │ tech,  │  │ ports │  │ critical+  │ │
│   │ status │  │       │  │ high only  │ │
│   └────────┘  └───────┘  └────────────┘ │
╰─────────────┬───────────────────────────╯
              │
              ▼
╭───────────────────────────╮     ╭─────────────────────────╮
│ finalize_scan/6           │────▶│ domain_metadata         │
│ - persist findings        │     │ open_ports, tech_stack, │
│ - upsert metadata         │     │ http_status, ...        │
│ - send :scan_done to LV   │     ╰─────────────────────────╯
╰─────────────┬─────────────╯
              │
              ▼
       LV refresh: latest_security_scan, severity_counts
              │
              ▼
       Template re-renders top badges, infrastructure
       chips, single scan card
```

## Acceptance criteria

1. Domain page shows exactly one "Run Security Scan" button (admin-only
   override removed).
2. After a successful scan:
   - `domain_metadata.open_ports` is populated and rendered as chips in
     Infrastructure.
   - `domain_metadata.tech_stack` is populated.
   - `domain_metadata.last_security_scan_at` is set.
   - Severity badge row at the top of the domain page reflects the current
     scan's findings.
3. Security Posture section shows only the latest completed scan (or the
   running scan, or an empty state). Never a list of historical scans.
4. Failed scans display the existing red error card with the admin "Delete"
   button (already implemented in a previous iteration).
5. `mix precommit` is green.

## Risks & mitigations

- **Lightweight nuclei misses real issues.** Acceptable trade-off chosen
  explicitly: the goal is fast feedback on the most serious classes of
  problems, not exhaustive auditing. Heavier scans can be reintroduced later
  as a separate "deep audit" entry point if needed.
- **Migration adds nullable fields, no backfill.** Existing domains will show
  empty open_ports / tech_stack until rescanned. This is intentional — no
  fabricated data.
- **`severity_counts_for_domain/1` runs an extra query on every page render.**
  The query hits an indexed `security_scan_id` join and groups a small set
  (typically < 100 findings). If profiling shows it as hot, cache to
  `domain_metadata` in a follow-up.
