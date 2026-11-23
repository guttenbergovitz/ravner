# Bulk Operations on Domain Listing

**Status:** Implemented

## Overview

The domain listing (`/domains`) supports bulk selection and actions. Users can select domains manually, select all visible, or select all matching current filters.

## Features

- **Selection Mode**: Toggleable mode that reveals checkboxes and an action bar.
- **Bulk Scan**: Triggers a quick scan for all selected domains. Supports an "Include subdomains" option.
- **Bulk Security Scan**: Triggers a native lightweight security scan (Curated Probes, TLS/Header audit, open port check) for selected domains. Supports an "Include subdomains" option.
- **Bulk Delete**: Removes selected domains and their associated subdomains (cascading).
- **Sticky Selection**: The `MapSet` of selected IDs survives page navigation.
- **Filter Guard**: Changing search or lifecycle filters clears the current selection to prevent accidental actions on stale data.

## Backend Implementation

- **Filter Mapping**: `Domains.ids_matching_filters/1` retrieves all IDs matching the active UI filters without pagination.
- **Concurrency & Throttling**:
  - Bulk quick scans use `Task.async_stream` with a configurable concurrency limit (default 5).
  - Bulk security scans execute via `SecurityRunner.run_security_scan_sync/3` within `Task.async_stream`, ensuring proper concurrency bounds and synchronous execution per domain task.
- **Permissions**:
  - `Viewer`: Read-only. Selection mode, bulk action bars, quick scan, and security scan buttons are hidden and unavailable.
  - `Editor`: Can select, execute bulk quick scans, execute bulk security scans, assign ownership (brand/org/project), and change lifecycle states.
  - `Admin`: Full permissions including bulk delete, bulk quick scans, bulk security scans, ownership assignment, and lifecycle changes.
