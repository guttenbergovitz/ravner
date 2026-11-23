# Task Scheduling & Heartbeats

**Status:** Implemented

## Overview

Ravner utilizes **Oban** (PostgreSQL-backed job queues) to handle all asynchronous work, ranging from heavy multi-tool security scans to high-frequency uptime heartbeats. To maintain scalability, the system avoids individual cron jobs per domain, instead employing the **Dispatcher Worker** pattern.

## Architecture: The Dispatcher Pattern

The scheduling system is entirely data-driven. Instead of populating the queue with thousands of future jobs, we run global Dispatchers that query the database for "due" tasks and enqueue them on demand.

### 1. Database Configuration

Domain automation is controlled via interval columns in `domain_metadata`:
- `scan_interval_days`: Full security pipeline (Naabu, Nuclei, CVE matching, etc.).
- `http_scan_interval_days`: Reachability and status check (native, `Req`-based).
- `dns_scan_interval_days`: Record and resolution check (native, `:inet_res`).
- `heartbeat_interval_minutes`: High-frequency uptime ping.
- `a11y_scan_interval_days`: Accessibility compliance scanning via `pa11y`.
- `lighthouse_scan_interval_days`: Performance, accessibility, SEO audits via Google Lighthouse.
- `ssl_check_interval_days`: Certificate validity, expiration date, and issuer checks.

### 2. The Heartbeat Engine

Implemented via `Ravner.Workers.HeartbeatWorker`.
- **Method**: Fast HTTP HEAD/GET request using `Req` (native).
- **Payload**: Inserts into `heartbeat_checks`, updates `domain_metadata.is_up` + `last_heartbeat_at`, and triggers downtime evaluation.
- **Isolation**: Runs on a dedicated `heartbeats` queue with high concurrency (50) to ensure pings are never delayed by long-running scans.

### 3. Active Dispatchers & Background Workers

Oban Cron and queue orchestrators trigger the following workers:
- **`HeartbeatDispatcher`** (Every minute): Enqueues `HeartbeatWorker` for domains due for an uptime ping.
- **`SecurityScanDispatcher`** (Hourly): Enqueues security scan jobs for domains due for full vulnerability scanning.
- **`HttpxScanDispatcher`** (Hourly): Enqueues HTTP reachability and technology probe jobs.
- **`DnsxScanDispatcher`** (Hourly): Enqueues native DNS record synchronization jobs.
- **`A11yScanDispatcher`** (Hourly): Enqueues `A11yScanWorker` jobs for WCAG accessibility audits.
- **`LighthouseScanDispatcher`** (Hourly): Enqueues `LighthouseScanWorker` for Lighthouse performance and best-practices audits.
- **`SslCheckDispatcher`** (Hourly): Checks SSL certificate remaining days and expiry.
- **`DomainCheckDispatcher`** (Hourly): Checks registration and domain expiration status.
- **`HeartbeatRetentionWorker`** (Daily): Automatically prunes historical `heartbeat_checks` older than the retention threshold.
- **`TechnologiesUpdateWorker`** (Daily): Refreshes the local Wappalyzer fingerprint database used by native tech detection (`Ravner.Scans.TechFingerprint`).
- **`UptimeNotificationWorker`** (Event-driven): Asynchronously dispatches email and SMS alerts upon downtime state changes.

Each dispatcher performs an efficient SQL fragment check to identify domains where `last_scanned_at + interval < NOW()`, enqueuing worker jobs on demand without queue bloat.

## Observability & Management

Administration is handled via the **Jobs Dashboard** (`/admin/jobs`):
- **Queue History**: Real-time view of executing, available, and completed jobs. High-frequency dispatchers are hidden by default to reduce noise.
- **Active Schedules**: A consolidated list of all domains with automation enabled, allowing administrators to disable all schedules for a specific domain with a single click.

