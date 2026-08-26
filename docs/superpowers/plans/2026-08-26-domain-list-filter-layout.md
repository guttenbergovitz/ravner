# Domain List Filter Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the domains-list header so `No domains yet` and filter chips never overlap.

**Architecture:** Keep existing LiveView behavior and events unchanged. Only refactor the header markup/classes in `domain_live/index.html.heex` to a two-line layout: status line first, filter row second with wrapping. Validate with formatting and compilation checks.

**Tech Stack:** Phoenix LiveView, HEEx, Tailwind utility classes, Mix.

---

### Task 1: Refactor header layout to vertical structure

**Files:**
- Modify: `lib/ravner_web/live/domain_live/index.html.heex`

- [ ] **Step 1: Confirm current single-row structure exists**

Run:

```bash
cd /Users/krzys/github.com/guttenbergovitz/ravner
rg -n 'flex items-center justify-between|No domains yet|Show empty|Monitored' lib/ravner_web/live/domain_live/index.html.heex
```

Expected: output shows the header currently uses one horizontal `flex items-center justify-between` block containing both status text and filter buttons.

- [ ] **Step 2: Replace header wrapper with two-line layout**

In `lib/ravner_web/live/domain_live/index.html.heex`, replace:

```heex
<div class="flex items-center justify-between">
  <p class="text-[10px] ...">...</p>
  <div class="flex items-center gap-2">
    ...
  </div>
</div>
```

with:

```heex
<div class="space-y-2">
  <p class="text-[10px] font-normal uppercase tracking-widest text-neutral-400">
    ...
  </p>
  <div class="flex flex-wrap items-center gap-2">
    ...
  </div>
</div>
```

Keep all existing `phx-click`, `aria-pressed`, `title`, and per-button state classes unchanged.

- [ ] **Step 3: Ensure no button text/functionality was removed**

Run:

```bash
cd /Users/krzys/github.com/guttenbergovitz/ravner
rg -n 'Subdomains|Show empty|Monitored|toggle_filter_subdomains|toggle_empty_facets|toggle_monitored_only' lib/ravner_web/live/domain_live/index.html.heex
```

Expected: all three labels and all three click handlers remain present.

### Task 2: Validate and finalize

**Files:**
- Validate: `lib/ravner_web/live/domain_live/index.html.heex`

- [ ] **Step 1: Format file**

Run:

```bash
cd /Users/krzys/github.com/guttenbergovitz/ravner
mix format lib/ravner_web/live/domain_live/index.html.heex
mix format --check-formatted
```

Expected: formatter runs cleanly with no pending formatting diff.

- [ ] **Step 2: Compile to ensure template integrity**

Run:

```bash
cd /Users/krzys/github.com/guttenbergovitz/ravner
mix compile --warnings-as-errors
```

Expected: compile succeeds with no template/LiveView compile errors.

- [ ] **Step 3: Commit**

Run:

```bash
cd /Users/krzys/github.com/guttenbergovitz/ravner
git add lib/ravner_web/live/domain_live/index.html.heex
git commit -m "fix(ui): separate domain header status from filter chips" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

Expected: one commit containing only the header layout fix.
