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

## 5. Strategic Shift: Enterprise Governance via Ash Framework

**Context**: Ravner's primary business value is not as a raw scanning engine, but as an enterprise governance and knowledge management platform for digital ecosystems. Scans exist to reduce organizational blindness, but the current Role-Based Access Control (RBAC) and inventory management logic is naive and scattered across UI layers.

**Planned Solution (Partial Ash Adoption)**:
We will transition the governance and inventory layers to the **Ash Framework** to provide enterprise-grade policies, auditability, and lifecycle workflows, while keeping the runtime orchestration in pure Elixir/Ecto/Oban.

**Implementation Boundaries**:
- **Ash Domain**: `Ravner.Inventory` (Brands, Orgs, Projects, Roles) and the ownership/lifecycle aspects of `Ravner.Domains`. This enables strict declarative authorization (Ash Policies) and automatic audit trails (AshPaperTrail) necessary for compliance.
- **Non-Ash Domain**: `Ravner.SystemCommand`, `Ravner.Scans`, and all Oban Dispatchers/Workers must remain pure Ecto/Elixir to maintain maximum I/O performance and avoid abstraction overhead during high-concurrency background processing.
- **Rollout**: Migration will be iterative, starting strictly with the `Ravner.Inventory` context to avoid cognitive overload and establish patterns before touching core domain routing.
