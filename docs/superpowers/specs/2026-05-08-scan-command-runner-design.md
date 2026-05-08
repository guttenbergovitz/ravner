# Scan Command Runner Design

## Goal

Reduce scanner process duplication and introduce a stable boundary that can later move from ad hoc supervised tasks to a dedicated scan queue or worker pool without rewriting LiveViews.

## Current State

Scanner command execution is implemented in three places:

- `Ravner.Scans` runs `dnsx` and `whois` through a local `cmd_with_timeout/3`.
- `Ravner.Scans.SecurityRunner` runs `httpx`, `naabu`, and `nuclei` through a local timeout wrapper that also isolates the spawned process group.
- `RavnerWeb.AdminLive.Settings` runs `nuclei -update-templates` through another local timeout wrapper.

The domain LiveViews also know the exact quick-scan pipeline by calling `run_dnsx_scan/1`, `run_httpx_scan/1`, `run_rdap_scan/1`, and `run_subdomain_scan/1` directly. Bulk scanning has a hard-coded `max_concurrency: 10`.

## Architecture

Add `Ravner.SystemCommand` as the single low-level command runner. Its public API will be:

```elixir
Ravner.SystemCommand.run_with_timeout(command, args, timeout, opts \\ [])
```

It will return:

```elixir
{output, exit_status}
{:error, :timeout}
{:error, reason}
```

The implementation must preserve the process-group behavior currently in `Ravner.Scans.SecurityRunner`: spawned CLIs run in their own process group and timeout cleanup terminates the group, not just the BEAM port owner.

Add scan orchestration helpers to `Ravner.Scans`:

```elixir
Ravner.Scans.run_quick_scan(domain_id)
Ravner.Scans.scan_max_concurrency()
```

`run_quick_scan/1` owns the current quick-scan sequence:

```elixir
run_dnsx_scan(domain_id)
run_httpx_scan(domain_id)
run_rdap_scan(domain_id)
run_subdomain_scan(domain_id)
```

`scan_max_concurrency/0` reads `:scan_max_concurrency` from application config and defaults to `5`.

## Data Flow

LiveViews continue to start background work through `Ravner.ScanTaskSupervisor`, but they no longer spell out the quick-scan steps. They call `Scans.run_quick_scan/1`.

Bulk scans still use `Task.async_stream/3`, but `max_concurrency` is read from `Scans.scan_max_concurrency/0`. This keeps the current behavior simple while making the limit explicit and configurable.

The future stronger design can replace the internals of `run_quick_scan/1` or add a queue-backed function beneath it. LiveViews should not need to change when that happens.

## Configuration

Add a default:

```elixir
config :ravner, :scan_max_concurrency, 5
```

Add runtime override:

```elixir
config :ravner,
  scan_max_concurrency:
    System.get_env("SCAN_MAX_CONCURRENCY", "5") |> String.to_integer()
```

If the runtime value is invalid, fail fast during boot rather than silently running with an accidental value.

## Error Handling

Domain-specific modules keep their existing user-facing error messages. For example, `Scans` may turn `{:error, :timeout}` into `"dnsx timed out after 30000ms"`.

`Ravner.SystemCommand` is responsible only for:

- executable lookup,
- port spawning,
- output collection,
- timeout detection,
- process group cleanup.

It does not know scanner names, LiveView state, database persistence, or flash messages.

## Testing

Add unit coverage for `Ravner.SystemCommand`:

- missing executable returns `{:error, "... executable not found"}` or an equivalent explicit message,
- successful command returns output and exit status,
- timeout returns `{:error, :timeout}`.

Add unit coverage for `Scans.scan_max_concurrency/0` with temporary application env.

Existing LiveView tests continue to cover rendering and interaction behavior. The implementation should finish with `mix precommit`.

## Non-Goals

This change will not introduce Oban, Broadway, GenStage, or a custom GenServer queue. It creates the boundary that makes that migration straightforward later.

This change will not redesign security scan progress tracking or persistence.
