# ADR 0005: Model Context Protocol (MCP) Server for Ash Governance Domains

**Status:** Accepted (Implemented)  
**Date:** 2026-09-26  
**Deciders:** Core Engineering Team  
**Consulted:** Ravner Architecture Team  

---

## 1. Context and Problem Statement

As Ravner has matured into an enterprise-grade Attack Surface Management (ASM) and infrastructure inventory platform, operators increasingly utilize autonomous AI agents, developer IDE assistants (such as Claude Code, Cursor, Windsurf), and centralized LLM orchestrators to query infrastructure topology and enforce governance lifecycles.

Prior to this decision, interacting with Ravner programmatically required either direct database queries, scraping LiveView web endpoints, or ad-hoc custom HTTP APIs. This approach posed three major architectural risks:

1. **Governance & Policy Bypass**: External scripts or naive API integrations risk bypassing declarative Ash policies (`Ash.Policy.Authorizer`) and scoped RBAC rules.
2. **Loss of Audit Trail**: Changes made outside of Ash resources do not generate `AshPaperTrail` version diffs attributing who changed what, when, and under which action contract.
3. **Violation of the Stop Line Mandate**: Unstructured LLM tool access could inadvertently trigger high-volume asynchronous scanners (Naabu, Nuclei, Katana, DNS brute-forcing) synchronously or flood Oban worker queues.

Ravner requires a standardized, secure **Model Context Protocol (MCP)** server enabling AI clients to discover and execute governance operations while strictly upholding the system's foundational architecture.

---

## 2. Decision Drivers

* **First-Class Ash Integration (`ash_ai`)**: Leverage the official Ash ecosystem (`ash_ai` with `req_llm`) to expose Ash actions directly as LLM tools with declarative JSON schemas.
* **Adherence to the "Stop Line" Rule**:
  * **Exposed Domain (Ash Governance)**: Only governance resources (`Ravner.Domains.AshDomain`, `Ravner.Inventory.AshDomain`, `Ravner.Accounts.AshDomain`) are exposed as MCP tools.
  * **Forbidden Domain (Performance Runtime)**: High-concurrency scanners, Oban worker queues, external tool execution (`Ravner.SystemCommand`), and raw data ingestion paths MUST NOT be exposed to LLM tool calling.
* **Mandatory Policy Authorization & PaperTrail Audit**:
  Every MCP request must resolve an authenticated actor (`%Ravner.Accounts.User{}`). `AshAi` automatically propagates the actor to Ash actions, executing `Ash.Policy.Authorizer` checks and creating `domains_versions` / `projects_versions` audit entries.
* **Deterministic Dependency Compatibility**:
  Maintain stability with the project's locked dependency tree (`ash ~> 3.24.7`, `ash_postgres 2.9`, `ash_paper_trail 0.3`).
* **Standard Protocol Compliance**:
  Full compliance with the Model Context Protocol (MCP) HTTP / JSON-RPC 2.0 specification (`initialize`, `tools/list`, `tools/call`).

---

## 3. Considered Options

### Option 1: Hand-Crafted Phoenix JSON Controller
Manually write Phoenix controllers implementing custom JSON-RPC endpoints and translating arguments to Ash changesets.
* *Critique*: High maintenance burden, fragile parameter validation, manual JSON schema synchronization, and failure to leverage standardized MCP client ecosystems.

### Option 2: Full Framework Upgrade to `ash_ai ~> 1.1` and `ash >= 3.33`
Force-upgrade the entire project to the latest Ash 3.33+ versions.
* *Critique*: High risk of regression across 180+ codebase modules, breaking changes in Ash authorizers/data layers, and unnecessary disruption to production stability.

### Option 3: Standard `ash_ai 1.0.2` Integration with Dedicated Auth Plug (Selected)
* Pin `ash_ai ~> 1.0.2` and `req_llm ~> 1.18`, which are 100% compatible with `ash 3.24.7` and `ash_paper_trail 0.3.1`.
* Mount `AshAi.Mcp.Router` behind a dedicated `:mcp_api` pipeline in `RavnerWeb.Router`.
* Implement `RavnerWeb.Plugs.RequireMcpAuth` to authenticate clients via Bearer token, X-API-Key, or user session token, populating the Ash actor on `conn` via `Ash.PlugHelpers.set_actor/2`.
* Expose curated governance tools on Ash Domains with explicit `select:` schemas and business descriptions.

---

## 4. Architecture and Implementation Details

### 4.1 Dependency Lock & Compatibility
The implementation integrates:
* `{:ash_ai, "~> 1.0.2"}`
* `{:req_llm, "~> 1.18"}`
* Compatible runtime dependencies: `dotenvy ~> 1.1`, `finch 0.23.0`.

### 4.2 Router Architecture & Endpoint
Mounted under `/mcp` in `lib/ravner_web/router.ex`:

```elixir
pipeline :mcp_api do
  plug :accepts, ["json"]
  plug RavnerWeb.Plugs.RequireMcpAuth
end

scope "/mcp" do
  pipe_through :mcp_api
  forward "/", AshAi.Mcp.Router, otp_app: :ravner
end
```

### 4.3 Authentication & Actor Propagation (`RequireMcpAuth`)
The plug supports:
1. `Authorization: Bearer <TOKEN>` (or `Basic`)
2. `X-API-Key: <TOKEN>` or `X-MCP-Token: <TOKEN>`
3. User session tokens (persisted in `users_tokens`).

When authenticated via `RAVNER_MCP_API_KEY`:
* Constant-time comparison prevents timing attacks (`Plug.Crypto.secure_compare/2`).
* Resolves designated `RAVNER_MCP_ACTOR_EMAIL` or assigns a dedicated system admin actor (`mcp-service@ravner.internal`).
* Sets the actor via `Ash.PlugHelpers.set_actor(conn, actor)`.

When authenticated via user session token:
* Looks up the user in `Ravner.Accounts` and sets the user struct as the Ash actor.

Unauthenticated or invalid requests receive an HTTP 401 with standard JSON-RPC `-32600` error payloads.

### 4.4 Exposed Governance Tool Catalog

Tools are declared using the Spark DSL `tools do ... end` on the respective Ash Domain modules:

| Domain | Tool Name | Resource | Action | Description |
|---|---|---|---|---|
| **Domains** | `list_domains` | `Domain` | `:read` | List discovered domains/subdomains with governance lifecycle & technical status |
| **Domains** | `get_domain` | `Domain` | `:read` (by `id`) | Retrieve full domain governance metadata by ID |
| **Domains** | `get_domain_by_name` | `Domain` | `:read` (by `name`) | Retrieve domain governance metadata by exact domain name |
| **Domains** | `set_domain_lifecycle` | `Domain` | `:set_lifecycle` | Update domain lifecycle state (audited via `AshPaperTrail`) |
| **Domains** | `assign_domain_project`| `Domain` | `:assign_project` | Assign domain to project, brand, or organization |
| **Domains** | `assign_domain_contacts`| `Domain` | `:assign_contacts` | Assign PM and PO contact emails |
| **Domains** | `list_domain_dns_records`| `DnsRecord` | `:read` | Query governance DNS records |
| **Domains** | `list_domain_tech_evidence`| `TechEvidence`| `:read` | Query detected technologies and evidence |
| **Inventory** | `list_projects` | `Project` | `:read` | List inventory projects with manager & org metadata |
| **Inventory** | `get_project` | `Project` | `:read` (by `id`) | Get project details by ID |
| **Inventory** | `get_project_by_slug` | `Project` | `:read` (by `slug`)| Get project details by slug |
| **Inventory** | `list_organizations` | `Organization` | `:read` | List organizations with type and country |
| **Inventory** | `get_organization` | `Organization` | `:read` (by `id`) | Get organization details by ID |
| **Inventory** | `list_brands` | `Brand` | `:read` | List portfolio brands |
| **Inventory** | `get_brand` | `Brand` | `:read` (by `id`) | Get brand details by ID |
| **Inventory** | `list_people` | `Person` | `:read` | List governance contacts and people |
| **Inventory** | `get_person` | `Person` | `:read` (by `id`) | Get person details by ID |
| **Inventory** | `list_project_repositories`| `ProjectRepository` | `:read` | List repositories attached to projects/domains |
| **Accounts** | `list_users` | `UserResource` | `:read` | List system users (requires admin/editor actor) |
| **Accounts** | `get_user` | `UserResource` | `:read` (by `id`) | Get user details (requires admin/editor actor) |

### 4.5 Stop Line Rule Enforcement
The MCP server strictly excludes:
- Scanner execution engines (`Ravner.Scans.*`).
- External command invocation (`Ravner.SystemCommand`).
- Oban worker job triggering or dispatching.
- Raw asynchronous bulk ingestion paths.

---

## 5. Security & Audit Verification

1. **Ash Policies**:
   Non-admin/editor actors (such as `:viewer`) are dynamically denied from seeing or invoking write tools (`set_domain_lifecycle`, `assign_domain_project`). Attempts return `-32602` (Tool not found) or `{:error, "forbidden"}`.
2. **Audit Trails**:
   Every lifecycle or assignment mutation executed via MCP creates an entry in `domains_versions` with `version_action_name: :set_lifecycle` and the exact attribute diffs.

---

## 6. Consequences

### Positive
* **Ecosystem Standard**: Ravner now natively supports Claude Desktop, Cursor, Windsurf, and custom autonomous LLM agents via standard MCP over HTTP.
* **Guaranteed Auditability**: Zero bypass of Ash policies or PaperTrail version tracking.
* **High Performance**: Reads and writes are scoped to explicit `select:` attributes, keeping JSON payload sizes minimal and query performance optimal.

### Negative / Trade-Offs
* Requires configuring `RAVNER_MCP_API_KEY` in production environments (managed alongside existing API secrets like `METRICS_BEARER_TOKEN`).
