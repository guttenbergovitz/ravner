# System Command Runner

**Status:** Implemented

## Goal

Provide a stable, unified boundary for executing external CLI tools (`naabu`, `nuclei`, `katana`, `lonkero`, `lighthouse`, `pa11y`, `whois`) while ensuring robust cleanup of orphaned processes.

DNS resolution, HTTP probing and Wappalyzer technology fingerprinting are
implemented natively in Elixir/Erlang (`:inet_res`, `Req`,
`Ravner.Scans.TechFingerprint`) and do not use this runner.

## Architecture: `Ravner.SystemCommand`

All external tool execution must go through `Ravner.SystemCommand.run_with_timeout/4`.

### Key Responsibilities

1.  **Process Isolation**: CLIs are spawned in their own process group (`PGID`).
2.  **Timeout Management**: If a command exceeds its timeout, the entire process group is terminated (SIGTERM/SIGKILL) to prevent "zombie" scanner processes.
3.  **Output Capture**: Standard output and error are combined and returned.
4.  **Exit Handling**: Returns clear tuples for success, timeout, or execution errors.

## Orchestration: `Ravner.Scans`

The `Scans` context uses the command runner to implement specific scanner logic:

- **Quick Scan**: A sequence of DNS resolution (native `:inet_res`) → HTTP probe (native `Req`) → `rdap/whois` → `subdomain_discovery`.
- **Concurrency Control**: `Scans.scan_max_concurrency/0` reads limits from application config (defaulting to 5), preventing system exhaustion during bulk operations.

## Configuration

- `config :ravner, :scan_max_concurrency, 5`
- Runtime override via `SCAN_MAX_CONCURRENCY` environment variable.
