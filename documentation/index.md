# Ravner Documentation Index

Welcome to the technical documentation repository for **Ravner**, the enterprise digital asset management, attack surface discovery, and infrastructure governance platform.

This index provides human operators, software engineers, and LLM-based autonomous agents with a clear roadmap of the system architecture, features, heuristics, and operational procedures.

---

## 🧭 Getting Started & Onboarding

| Document | Description | Target Audience |
|---|---|---|
| [**System Onboarding Guide**](onboarding.md) | Comprehensive introduction covering system purpose, core mental model, architectural mandates ("Stop Line"), scanner pipeline, RBAC, and developer workflows. | New Developers, Human Operators, LLM Agents |
| [**Architecture Roadmap**](architecture/roadmap.md) | Technical debt tracking, scaling boundaries, and future evolutionary milestones. | Architects, Senior Engineers |
| [**Ash Migration Plan**](architecture/ash-migration-plan.md) | Architectural strategy for enterprise governance, policy enforcement, and auditability. | Backend Engineers, Architects |
| [**Ash Migration Checklist**](architecture/ash-migration-checklist.md) | Concrete execution status of the Ash adoption plan and regression guardrails. | Engineers, Tech Leads |
| [**Hardening & Remediation Plan**](architecture/hardening-and-remediation-plan.md) | Six-phase architectural hardening rollout (completed in v0.18.0) covering security policies, audit trails, process isolation, LiveView streams, and code hygiene. | Architects, Core Engineers |

---

## 🏛️ Architecture & System Design

Ravner is built as a hybrid architecture balancing high-throughput asynchronous ingestion with strict declarative governance:

| Area | Document | Focus |
|---|---|---|
| **External Execution Boundary** | [**Command Runner**](architecture/command-runner.md) | Process isolation (`PGID`), timeout enforcement, zombie process mitigation via `Ravner.SystemCommand`. |
| **Vulnerability Intelligence** | [**CVE Intelligence & Caching**](architecture/cve-vulnerability-intelligence.md) | Real-time upstream correlation (Google OSV.dev, GHSA, NVD), L1 ETS + L2 PostgreSQL caching, zero-payload passive matching. |
| **Task Orchestration** | [**Scheduling & Heartbeats**](architecture/scheduling-and-heartbeats.md) | Oban-driven database dispatchers, background worker pools, cron jobs, retention policies. |
| **Ash/Ecto Boundaries** | [**Ash and Ecto Domain Boundaries**](architecture/domain-boundaries.md) | Governance actions, runtime ingestion, authorization, and audit stop line. |
| **Architecture Decisions** | [**ADR 0001: Native Lightweight Security Scanner**](architecture/adr/0001-native-lightweight-security-scanner.md) | Accepted (Implemented) — In-process BEAM security probes replacing heavy external Nuclei runs for primary monitoring. |
| | [**ADR 0002: Dual-Tree Hierarchical Scoped RBAC**](architecture/adr/0002-dual-tree-hierarchical-scoped-rbac.md) | Accepted (Implemented) — Fine-grained scoped permissions across Brand and Organization hierarchies. |
| | [**ADR 0003: Unified Observability & OpenTelemetry Architecture**](architecture/adr/0003-unified-observability-opentelemetry-architecture.md) | Accepted (Implemented) — OpenTelemetry semantic conventions, Prometheus `/metrics`, and live event inspector. |
| | [**ADR 0004: Enterprise ASM, SBOM, Secrets & Risk Engine**](architecture/adr/0004-enterprise-security-governance-extensions.md) | Accepted (Implemented) — Native CycloneDX 1.5 SBOM generator, repo secrets detection, ChatOps webhooks, and executive risk scoring. |
| | [**ADR 0005: AshAi Model Context Protocol (MCP) Server**](architecture/adr/0005-ash-ai-model-context-protocol-governance-server.md) | Accepted (Implemented) — Official `ash_ai` MCP server exposing Ash governance domains as tools for LLMs with full policy and audit enforcement. |
| | [**ADR 0006: Enterprise Architecture Modeling**](architecture/adr/0006-enterprise-architecture-modeling.md) | Accepted (Implemented) — Applications, value streams, business capabilities, datastores, and ArchiMate 3.1 XML export. |
| | [**ADR 0007: Ash JSON:API & OpenAPI Swagger Architecture**](architecture/adr/0007-ash-json-api-openapi-swagger-architecture.md) | Accepted (Implemented) — Automated JSON:API v1.1 and OpenAPI 3.0 endpoints for governance resources. |
| | [**ADR 0008: API Token Governance (Source IP & URL Scoping)**](architecture/adr/0008-api-token-governance-source-and-url-scoping.md) | Accepted (Implemented) — SHA-256 hashed enterprise API tokens with CIDR allowlists, URL path scoping, and role delegation. |

---

## 🚀 Features & Capabilities

Detailed specifications of core capabilities and user-facing workflows:

| Feature | Document | Key Capabilities |
|---|---|---|
| **Access Control & RBAC** | [**Access Control**](features/access-control.md) | Three-tier permissions (`:admin`, `:editor`, `:viewer`), router pipelines, Ash policies, active user lifecycle, user invitation. |
| **Governance Audit Trail** | [**Access Control & Audit Trail**](features/access-control.md#5-governance-audit-trail--compliance-ashpapertrail) | AshPaperTrail version tracking, reactive domain lifecycle & ownership timeline in LiveView. |
| **Uptime Monitoring & Alerting** | [**Uptime Monitoring**](features/uptime-monitoring.md) | Continuous heartbeats, state flip detection, `downtime_windows`, multi-channel alerts (Email via Swoosh, SMS via AWS SNS/Twilio/Log), governance notes. |
| **Bulk Operations** | [**Bulk Operations**](features/bulk-operations.md) | Multi-domain selection, bulk quick scans, bulk security scans, bulk lifecycle changes, bulk ownership assignment, bulk deletion with RBAC safeguards. |
| **Unified Security Scanner** | [**Security Scanner**](features/security-scanner.md) | Native 4-phase security pipeline (Curated Probes, TLS/Header Audit, Zero-Lag CVEs, Ports), dedicated report view, darknet breach intelligence, portfolio threat posture. |

---

## 🧠 Heuristics & Decision Logic

| Topic | Document | Contents |
|---|---|---|
| **Classification & Discovery** | [**Domain Heuristics**](heuristics/general.md) | HTTP status code mapping, lifecycle states (Priority, Active, Under Review, Deprecated, Abandoned), subdomain discovery tiering (Chaos -> HackerTarget -> crt.sh). |

---

## ⚡ Architectural Golden Rules ("The Stop Line")

When designing or modifying code in Ravner, you must observe the boundary defined in [`GEMINI.md`](../GEMINI.md) and [`AGENTS.md`](../AGENTS.md):

1. **Governance Domain (Ash Framework)**:
   - `Ravner.Inventory.*` (Brands, Organizations, Projects, People, ProjectRoles).
   - `Ravner.Accounts.*` (User governance and policies).
   - `Ravner.Domains.Domain` (Ownership assignment, lifecycle transitions, and `AshPaperTrail` auditability).
2. **Performance Runtime (Pure Ecto / Oban)**:
   - `Ravner.Scans.*`, `Ravner.SecurityScans.*` (Scanner pipelines and network probes).
   - `Ravner.Workers.*` (Oban dispatchers and scheduled workers).
   - High-volume data tables: `domain_discovered_urls`, `domain_tech_evidence`, `domain_dns_records`, `heartbeat_checks`.
   - External CLI execution via `Ravner.SystemCommand`.
