# 8. Enterprise API Token Governance, Source IP and URL Pattern Scoping

Date: 2026-10-08

## Status
Accepted

## Context
With the introduction of the declarative JSON:API and OpenAPI Swagger UI (ADR 0007), Ravner exposes programmatic endpoints to query and manage digital assets (`/api/v1/applications`, `/api/v1/domains`, `/api/v1/projects`, etc.).

To ensure enterprise-grade security and prevent unauthorized access or token leakage risks:
1. API access cannot rely solely on static environment variables (`RAVNER_API_KEY`) or ephemeral browser sessions.
2. Administrators require fine-grained governance over API tokens: lifecycle management, acceptable source network perimeters (IP / CIDR allowlisting), request URL pattern scoping, and immediate revocation.
3. Access control must follow the **Principle of Least Privilege** and be **Secure by Default** (defaulting to read-only access).
4. Management of API tokens must be strictly restricted to the `:admin` role.

---

## Decision

We will implement a dedicated Ash governance resource `Ravner.Accounts.ApiToken` and update the authentication plug `RavnerWeb.Plugs.RequireApiAuth`:

### 1. Security & Storage Model
* **One-Way Token Hashing**: API tokens are generated using a 32-byte secure random string with a standardized prefix (`rav_live_<random_bytes>`).
* **Cryptographic Storage**: Only the SHA-256 digest (`token_hash`) is stored in the database. The raw token is presented to the administrator **only once** upon generation.
* **Display Prefix**: The first 12 characters (`prefix`: e.g. `rav_live_a1b2...`) are retained for auditing and UI identification.

### 2. Fine-Grained Authorization & Least Privilege ("Secure by Default")
* **Default Role**: Newly generated tokens default to the `:viewer` role (read-only queries), preventing accidental write access. Full write permissions (`:editor` or `:admin`) must be deliberately selected by the administrator.
* **Network Perimeter (Acceptable Source IPs)**: Tokens can define an optional `allowed_ips` list containing explicit IP addresses or CIDR blocks (e.g. `["192.168.1.50", "10.0.0.0/8"]`). Requests originating from unlisted IPs are rejected with `403 Forbidden`.
* **Path & Method Scoping (`allowed_paths`)**: Tokens can define route pattern matchers (e.g. `["GET /api/v1/applications*", "GET /api/v1/domains*"]`). Requests to endpoints not covered by the patterns are rejected with `403 Forbidden`.

### 3. Lifecycle & Immediate Revocation
* **Expiration (`expires_at`)**: Tokens support configurable expiration periods (30 days, 90 days, 1 year, custom, or never-expiring).
* **Instant Revocation (`revoked_at`)**: Administrators can revoke a token with a single click, rendering it immediately invalid across all API endpoints.
* **Usage Telemetry**: Records `last_used_at` and `last_used_ip` to monitor inactive or active integration clients.

### 4. Administrative Role Enforcement & Audit Trail
* **Strict Admin Boundary**: In accordance with project policy, only users with the `:admin` role are permitted to create, view, or revoke API tokens (`Ash.Policy.Authorizer` and Phoenix router `:admin` scope).
* **Audit Trail**: Backed by `AshPaperTrail` to record who generated or revoked each token.

---

## Consequences

* **Positive**:
  * Fine-grained, auditable, and revocable programmatic access.
  * Granular network isolation via CIDR allowlists and path scoping.
  * Zero exposure of raw token secrets in persistent storage.
  * Native alignment with Ash policies and role-based access control.
* **Negative**:
  * Adds database migration for `api_tokens` table and audit versioning.
