# Lean Security Scanner & Composed Domain View

**Status:** Implemented

## Problem

The previous security scanner was fragmented:
- Multiple parallel entry points (`naabu`, `nuclei`, `httpx`, `deep_scan`) producing separate records.
- UI rendered a stream of historical scans with no clear "latest state".
- Open ports were not surfaced outside of raw findings.
- Nuclei was over-scoped, leading to timeouts and noise.

## Solution: The Unified Security Scan

We replaced the multi-mode scanner with a single **Security Scan** that:

1.  **Pipeline**: Runs `httpx` → `naabu` → a tightly-scoped `nuclei` pass (critical/high severity only).
2.  **Persistence**: Meaningful results (open ports, tech stack, HTTP status) are upserted into `domain_metadata`.
3.  **UI**: Surfaces only the **latest** scan status and a severity badge row (Critical/High/Medium/Low) at the top of the domain page.
4.  **Integration**: Open ports are rendered as mono chips in the Infrastructure section.

## Architecture

- **Runner**: `Ravner.Scans.SecurityRunner.run_security_scan/2` handles the orchestration.
- **Nuclei Scope**: Restricted to `http,ssl,exposure` tags and `critical,high` severity against standard ports (80/443).
- **Metadata Upsert**: Post-scan, `finalize_scan/6` updates `domain_metadata` with the discovered topology and tech details.
