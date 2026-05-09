# Task Scheduling & Heartbeats

**Status:** Implemented

## Overview

Ravner utilizes **Oban** (PostgreSQL-backed job queues) to handle all asynchronous work, ranging from heavy multi-tool security scans to high-frequency uptime heartbeats. To maintain scalability, the system avoids individual cron jobs per domain, instead employing the **Dispatcher Worker** pattern.

## Architecture: The Dispatcher Pattern

The scheduling system is entirely data-driven. Instead of populating the queue with thousands of future jobs, we run global Dispatchers that query the database for "due" tasks and enqueue them on demand.

### 1. Database Configuration

Domain automation is controlled via interval columns in `domain_metadata`:
- `scan_interval_days`: Full security pipeline (Naabu, Nuclei, etc.).
- `http_scan_interval_days`: Reachability and status check (`httpx`).
- `dns_scan_interval_days`: Record and resolution check (`dnsx`).
- `heartbeat_interval_minutes`: High-frequency uptime ping.

### 2. The Heartbeat (Poor Man's StatusCake)

Implemented via `Ravner.Workers.HeartbeatWorker`.
- **Method**: Fast HTTP HEAD/GET request using `httpx`.
- **Payload**: Updates `is_up` and `last_heartbeat_at`.
- **Isolation**: Runs on a dedicated `heartbeats` queue with high concurrency (50) to ensure pings are never delayed by long-running scans.

### 3. Global Dispatchers

Oban Cron triggers the following dispatchers:
- `HeartbeatDispatcher` (Every minute)
- `SecurityScanDispatcher` (Every hour)
- `HttpxScanDispatcher` (Hourly)
- `DnsxScanDispatcher` (Hourly)

Each dispatcher performs an efficient SQL fragment check to identify domains where the `last_scanned_at + interval < NOW()`, enqueuing the appropriate worker for each match.

## Observability & Management

Administration is handled via the **Jobs Dashboard** (`/admin/jobs`):
- **Queue History**: Real-time view of executing, available, and completed jobs. High-frequency dispatchers are hidden by default to reduce noise.
- **Active Schedules**: A consolidated list of all domains with automation enabled, allowing administrators to disable all schedules for a specific domain with a single click.

