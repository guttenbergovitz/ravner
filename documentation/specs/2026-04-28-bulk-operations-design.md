# Bulk Operations on Domain Listing

**Date:** 2026-04-28  
**Status:** Approved

## Overview

Add bulk select → action flow to the domain listing (`/domains`). Users can enter selection mode, pick domains (individually, all visible, or all matching active filters), optionally include subdomains, then execute scan or delete with a confirmation modal.

## UX Flow

### Entering selection mode

- Header gains a **"Select"** button (`btn-line text-xs`) alongside Import / Add domain
- Clicking sets `@selection_mode = true`
- Import and Add domain buttons are replaced by the action bar
- Leaving selection mode (Cancel or after action) resets `@selected_ids` and `@include_subdomains`

### Selection controls

Checkboxes appear to the left of each domain row (before the lifecycle dot).

- `phx-click="toggle_select" phx-value-id={domain.id}` — toggles individual domain
- **"Select all matching (N)"** — selects all IDs matching active filters across all pages, via `Domains.ids_matching_filters/1`
- **"Select visible (N)"** — selects only the IDs on the current page
- Both appear as checkboxes in the action bar header area
- `@selected_ids` is a `MapSet` — survives page navigation, resets on filter change

### Action bar (replaces header buttons when `@selection_mode`)

```
[ ☐ Select all matching (N) ] [ ☐ Select visible (N) ]
·  M selected  [ ☐ Include subdomains ]  [ Scan ]  [ Delete ]  [ ✕ Cancel ]
```

- **Scan** — available to all authenticated users
- **Delete** — available to editors and admins only (hidden for viewers)
- **Include subdomains** checkbox — `@include_subdomains = false` by default; affects both scan and delete confirmation count
- Both actions open a confirmation modal before executing

### Confirmation modal

Same style as existing modals (`fixed inset-x-0 top-20 bottom-8`, `border border-neutral-200`):

- Title: "Scan M domains" / "Delete M domains" (+ "+ N subdomains" when `@include_subdomains`)
- Domain list: first 5 names, then "+ K more" if over 5
- Buttons: **Confirm** (`btn-line-filled`) / **Cancel** (`btn-line`)
- After confirm: flash info message, exit selection mode, refresh listing

### Filter interaction

- Changing search or lifecycle filter while in selection mode clears `@selected_ids` (avoids stale selection)
- "Select all matching" uses the same filter state as the current listing

## Backend

### New: `Domains.ids_matching_filters/1`

```elixir
def ids_matching_filters(opts \\ []) :: [integer]
```

Same filter logic as `list_domains_filtered/1` but without pagination, returning only `[id]`. Used to power "select all matching".

### New: `Domains.bulk_delete/1`

```elixir
def bulk_delete(ids) :: {:ok, count} | {:error, reason}
```

Deletes all domains with the given IDs. Subdomains cascade via DB foreign key — no explicit subdomain deletion needed. Returns count of deleted records.

### Scan execution

No new context function needed. For each selected domain ID the LiveView calls `Scans.run_scan_all/1` via `Task.async_stream` with `ordered: false, timeout: :infinity`. When `@include_subdomains` is true, also iterates `domain.subdomains` and runs `Scans.run_scan_all/1` per subdomain.

## LiveView changes (`DomainLive.Index`)

### New assigns

| Assign | Type | Default | Description |
|---|---|---|---|
| `@selection_mode` | boolean | `false` | Whether selection UI is visible |
| `@selected_ids` | MapSet | `MapSet.new()` | Selected domain IDs |
| `@include_subdomains` | boolean | `false` | Include subdomains in bulk action |
| `@bulk_action` | atom / nil | `nil` | `:scan` or `:delete` — which confirmation modal to show |

### New events

| Event | Params | Action |
|---|---|---|
| `"enter_selection_mode"` | — | `@selection_mode = true` |
| `"exit_selection_mode"` | — | reset selection assigns |
| `"toggle_select"` | `id` | toggle ID in `@selected_ids` |
| `"select_all_matching"` | — | load all matching IDs, put in `@selected_ids` |
| `"select_visible"` | — | put current page domain IDs in `@selected_ids` |
| `"toggle_include_subdomains"` | — | flip `@include_subdomains` |
| `"bulk_action_confirm"` | `action` | set `@bulk_action`, show modal |
| `"bulk_action_execute"` | — | execute `@bulk_action` on `@selected_ids` |
| `"bulk_action_cancel"` | — | clear `@bulk_action` |

### Filter change side-effect

`apply_action/3` for `:index` clears `@selected_ids` when filter params differ from current assigns.

## Permissions

- **Viewer** — can enter selection mode, scan; Delete button hidden
- **Editor / Admin** — full access

## Out of scope

- Progress tracking per-domain during bulk scan (fire-and-forget, single flash on completion)
- Undo for bulk delete
- Bulk lifecycle state change (separate feature if needed later)
