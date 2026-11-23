# 7. Ash JSON:API, OpenAPI Specification & Swagger UI Architecture

Date: 2026-10-08

## Status
Accepted

## Context
Ravner currently exposes digital governance features through Phoenix LiveView administrative dashboards, CycloneDX SBOM exporters, ArchiMate exports, Prometheus metrics, and an AI-driven Model Context Protocol (MCP) server (`/mcp`).

However, external systems, CI/CD automation pipelines, enterprise service catalogs, and developers require a programmatic HTTP REST API to query and manage governance and inventory resources:
* Applications (`Ravner.Inventory.Application`)
* Domains (`Ravner.Inventory.Domain`)
* Projects (`Ravner.Inventory.Project`)
* Organizations & Brands (`Ravner.Inventory.Organization`, `Ravner.Inventory.Brand`)

Key architectural questions:
1. How should the REST API be implemented to avoid duplication of business rules and authorization while adhering to the Stop Line rule?
2. How should interactive API documentation (OpenAPI 3.0 / Swagger UI) be generated and maintained?
3. How should the API relate to semantic web standards such as **Schema.org**?

---

## Decision

We will implement a declarative REST API using `ash_json_api` and `open_api_spex`, following the native conventions of the Ash Framework:

### 1. Stop Line Alignment
In accordance with [`GEMINI.md`](../../../GEMINI.md) and [`AGENTS.md`](../../../AGENTS.md):
* **Governance Resources via AshJsonApi**: The API exposes governance and inventory resources (`Application`, `Domain`, `Project`, `Organization`, `Brand`) where authorization policies (`Ash.Policy.Authorizer`) and audit trails (`AshPaperTrail`) are required.
* **Telemetry & Runtime Bypass**: High-volume telemetry (scanners, bulk DNS records, crawl logs) will **not** be exposed via `AshJsonApi`, preserving runtime performance.

### 2. "Fire-and-Forget" Declarative Specification
Rather than manually writing Phoenix controllers and custom OpenAPI schemas (which drift and require perpetual maintenance):
* We use `AshJsonApi.Resource` directly on Ash resources (`json_api do ... end`).
* Standard JSON:API capabilities (filtering, sorting, pagination, sparse fieldsets, sideloading via `include`) are inherited automatically.
* OpenAPI 3.0 specifications are generated programmatically by `ash_json_api` / `OpenApiSpex` at `/api/v1/openapi.json`.
* An interactive **Swagger UI** is mounted at `/api/swagger-ui`.
* Adding or modifying an attribute in an Ash resource automatically updates the OpenAPI contract and Swagger UI without manual edits.

### 3. Separation of Concerns: OpenAPI vs. Schema.org
* **REST API & Swagger UI**: Adheres strictly to JSON:API v1.1 and OpenAPI 3.0 for operational, transactional machine-to-machine integration.
* **Schema.org (Linked Data / JSON-LD)**: Schema.org is a semantic taxonomy designed for search engines and web crawlers, not operational CRUD protocols. Forcing Schema.org directly into Swagger UI would break the "fire-and-forget" automation and require brittle manual transformation layers.
* **Resolution**: Schema.org compliance is decoupled from the REST API contract. Where Schema.org representation is needed (e.g. `schema.org/SoftwareApplication`), it is rendered via `<script type="application/ld+json">` in the HTML/LiveView presentation layer using dedicated presenters, keeping both layers idiomatic and low-maintenance.

### 4. Authentication & Policies
* Requests to `/api/v1` pass through the API pipeline.
* Policies defined in `policies do ... end` on Ash resources are automatically enforced against the resolved actor.

---

## Consequences

* **Positive**:
  * Fully automated, standards-compliant JSON:API v1.1.
  * Zero-maintenance OpenAPI 3.0 documentation and interactive Swagger UI.
  * Consistent enforcement of Ash policies and audit trails.
* **Negative**:
  * Introduces `:ash_json_api` (~> 1.7) and `:open_api_spex` (~> 3.22) dependencies.
