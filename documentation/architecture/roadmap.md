# Architecture Roadmap & Future Improvements

This document outlines known architectural bottlenecks and the planned technical evolution of Ravner as it scales.

## 1. JSONB Normalization (The "Big Blob" Problem)

**Issue**: The `domain_metadata` table currently functions as a catch-all container. Storing large, unstructured arrays (e.g., `discovered_urls`, `tech_evidence`) within a single JSONB column will lead to significant I/O overhead and memory pressure on the BEAM as the domain count grows.

**Planned Solution**: Normalize heavy arrays into dedicated 1:N relational tables. This keeps the core metadata row lean and allows for more efficient querying and indexing of discovery data.

## 2. Temporal Visibility (Snapshots & History)

**Issue**: The system currently persists only the "latest known state." Every scan overwrites existing metadata, making it impossible to track changes over time or provide the historical audit trails required for compliance.

**Planned Solution**: Implement a snapshotting mechanism or a dedicated audit-log table. This will allow users to view the evolution of a domain's infrastructure and security posture over time.

## 3. Resource Exhaustion (OS & Network Limits)

**Issue**: While Elixir handles thousands of processes with ease, the underlying OS and network stack have finite limits on file descriptors and concurrent sockets. Aggressive use of CLI tools like `httpx` or `nuclei` in bulk can lead to resource exhaustion on the host machine.

**Planned Solution**: Maintain strict concurrency limits via Oban queues and implement active monitoring of host-level `ulimit` and network saturation.

## 4. Tooling Abstraction (Adapter Pattern)

**Issue**: Logic for executing and parsing external tools (e.g., `webanalyze`) is currently tightly coupled within workers. Any breaking change in a tool's output format will require manual updates to worker logic.

**Planned Solution**: Introduce a "Parser/Adapter" architectural layer. This abstraction will decouple the execution of external binaries from data ingestion, making it easier to add new tools or update existing ones without touching core business logic.
