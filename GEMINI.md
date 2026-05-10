# Ravner Engineering Mandates

This document establishes foundational architectural rules and coding standards for Ravner. These mandates take precedence over general defaults.

## Hybrid Architecture (The "Stop Line" Rule)

Ravner uses a deliberate split between governance logic and performance-critical runtime orchestration.

1.  **Governance Domain (Ash Framework)**:
    - ALL Inventory management (`Ravner.Inventory.*`), Role-Based Access Control (Ash Policies), and Domain lifecycle state transitions MUST be implemented using **Ash Framework**.
    - Use `ash_paper_trail` on all Ash Resources to maintain auditability.
    - Prefer `AshPhoenix.Form` for all administrative UI forms.

2.  **Performance Runtime (Pure Ecto/Oban)**:
    - High-concurrency background processing, scanner orchestration (`Ravner.Scans.*`), and heavy data ingestion (e.g., DNS records, tech evidence, crawled URLs) MUST bypass the Ash layer.
    - Use pure **Ecto** and **Oban** for these operations to minimize abstraction overhead and ensure linear scalability.
    - External tool execution must always go through `Ravner.SystemCommand` to ensure PGID-level process cleanup.

## Data Normalization Mandates

- DO NOT store growing arrays (URLs, tech evidence, detailed DNS lists) as JSONB blobs in the `domain_metadata` table.
- Large discovery results MUST be stored in dedicated 1:N normalized relational tables (e.g., `domain_discovered_urls`) to maintain efficient I/O and memory usage.

## Development Standards

- **Strict Typing**: Public context functions MUST have `@spec` annotations.
- **Testing**: Maintain 100% green suite status. New features must include regression tests.
- **Tone**: Professional, no-nonsense technical communication.
