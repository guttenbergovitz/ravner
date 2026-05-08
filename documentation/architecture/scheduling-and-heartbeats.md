# Task Scheduling & Heartbeats

**Status:** Proposed

## Problem

As Ravner scales, relying on `Task.Supervisor` and in-memory process groups for bulk scanning and cyclic execution becomes brittle.
- **Scheduling:** Users want to define "scan this every week" or "scan this every 30 days" per domain. Relying on a static global CRON or in-memory timers doesn't scale and makes UI-driven configuration difficult.
- **Resilience:** If the BEAM node restarts during a bulk operation of 5,000 domains, the queue is lost.
- **Uptime Monitoring:** We want a "poor man's StatusCake" — a fast, lightweight heartbeat check to verify domain uptime at high frequency (e.g., every 5 minutes), completely separate from the heavy security scanner.

## Architecture: Oban + Dispatcher Pattern

We will adopt **Oban** (PostgreSQL-backed job queues) to handle all asynchronous work. Instead of creating thousands of individual cron jobs, we will use the **Dispatcher Worker** pattern.

### 1. Database Schema Additions

Domains (or their settings) will gain interval configurations for any supported test type:
- `scan_interval_days`: Integer. How often to run the full security pipeline. `nil` means manual only.
- `heartbeat_interval_minutes`: Integer. How often to ping the domain for uptime. `nil` means disabled.
- `ssl_check_interval_days`: Integer. Fast, daily checks for expiration.
- `tech_discovery_interval_days`: Integer. Heavy, infrequent `katana` runs.

### 2. The Heartbeat (Poor Man's StatusCake)

A new, extremely lightweight worker: `Ravner.Workers.HeartbeatWorker`.
- **Purpose:** Fires a fast HTTP GET/HEAD request.
- **Action:** Updates a new field `is_up` (boolean) and `last_heartbeat_at` on `domain_metadata`. If the status changes (e.g., 200 -> 502), it can trigger a lifecycle state change or a notification in the future.
- **Queue:** Runs on a dedicated, high-concurrency Oban queue (e.g., `queues: [heartbeats: 50]`).

### 3. The Dispatcher Pattern (Scalable Cron)

Instead of a static cron for every test, we configure global Dispatcher jobs in Oban:

1.  **`Ravner.Workers.HeartbeatDispatcher`** (Runs every minute)
2.  **`Ravner.Workers.SecurityScanDispatcher`** (Runs every hour)
3.  **`Ravner.Workers.SslCheckDispatcher`** (Runs daily)

**How a Dispatcher works:**
When a Dispatcher runs, it executes a single Ecto query. For example, `SslCheckDispatcher` asks:
*"Find all domains where `ssl_check_interval_days` is not null AND (`ssl_scanned_at` is null OR `ssl_scanned_at` + interval < NOW())."*

For every matching domain, the dispatcher enqueues a specific worker (`SslCheckWorker`). 

**Why this scales to any test:**
- **Zero collisions:** A 5-minute heartbeat and a 30-day deep crawl run entirely independently.
- **Queue Segregation:** We isolate resources based on job weight.
  ```elixir
  queues: [
    heartbeats: 50, # Fast HTTP pings, high concurrency
    ssl_checks: 20, # Fast certificate fetches
    scans: 5,       # Medium weight (httpx, naabu)
    deep_tech: 2    # Heavy CPU/IO (katana), strictly limited
  ]
  ```
- **UI Driven:** The frontend provides simple toggles (e.g., "Check SSL: Daily", "Deep Scan: Monthly"). The UI just updates the database interval columns, and the Dispatchers automatically pick up or drop the schedules.

### 4. Bulk Operations via Oban

The bulk operations UI currently uses `Task.async_stream`. This will be swapped to inserting Oban jobs.

```elixir
# Bulk scan execution becomes an insert-loop
for id <- selected_ids do
  %{
    domain_id: id,
    scan_type: "security_scan",
    include_subdomains: include_subdomains?
  }
  |> Ravner.Workers.ScanWorker.new()
  |> Oban.insert()
end
```

**Benefits:**
- **Zero blocking:** The UI responds instantly with "Added N domains to the scan queue".
- **Rate limiting:** The `scans` queue processes them at the exact concurrency limit defined in our configuration, protecting the host OS from process exhaustion.
- **Granularity:** Jobs carry their specific payload. Some jobs in the queue might have `include_subdomains: true`, others `false`. Oban handles them individually.

## Dashboard & Observability

We will install `oban_live_dashboard` to inject queue monitoring into Phoenix LiveDashboard. This gives engineers and admins a free UI at `/dev/dashboard` to pause queues, inspect failed jobs, and view cron execution history without writing any custom administration views.
