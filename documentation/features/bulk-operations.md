# Bulk Operations on Domain Listing

**Status:** Implemented

## Overview

The domain listing (`/domains`) supports bulk selection and actions. Users can select domains manually, select all visible, or select all matching current filters.

## Features

- **Selection Mode**: Toggleable mode that reveals checkboxes and an action bar.
- **Bulk Scan**: Triggers a quick scan for all selected domains. Supports an "Include subdomains" option.
- **Bulk Delete**: Removes selected domains and their associated subdomains (cascading).
- **Sticky Selection**: The `MapSet` of selected IDs survives page navigation.
- **Filter Guard**: Changing search or lifecycle filters clears the current selection to prevent accidental actions on stale data.

## Backend Implementation

- **Filter Mapping**: `Domains.ids_matching_filters/1` retrieves all IDs matching the active UI filters without pagination.
- **Concurrency**: Bulk scans use `Task.async_stream` with a configurable concurrency limit (default 5).
- **Permissions**:
  - `Viewer`: Can select and scan.
  - `Editor/Admin`: Can select, scan, and delete.
