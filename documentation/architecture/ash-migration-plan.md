# Ash Framework Migration Plan

**Status:** Implemented

## Objective
Transition Ravner's governance, inventory, and authorization layers to the [Ash Framework](https://ash-hq.org/) while strictly preserving the high-performance Ecto/Oban runtime for background scanning and orchestration. This shift aligns the architecture with Ravner's core business value: providing enterprise-grade governance over digital ecosystems.

## Strategic Boundaries

**What WILL be migrated to Ash:**
- `Ravner.Inventory` (Brands, Organizations, Projects, Roles, Persons)
- `Ravner.Accounts` (Users, Tokens, basic identity)
- Parts of `Ravner.Domains` concerning lifecycle, ownership, and tagging.

**What WILL NOT be migrated to Ash (The "Stop Line"):**
- `Ravner.Scans` and `Ravner.SecurityScans` (Runtime orchestration)
- `Ravner.SystemCommand` (External CLI execution)
- `Ravner.Workers.*` (Oban dispatchers and workers)
- Raw discovery tables (`domain_dns_records`, `domain_tech_evidence`, `domain_discovered_urls`)

## Phased Action Plan

### Phase 1: Foundation & Inventory Migration
*Goal: Establish Ash patterns in the safest, most relational part of the system.*

1. **Install Ash Dependencies**: Add `ash`, `ash_postgres`, and `ash_phoenix` to `mix.exs`.
2. **Convert Inventory Schemas**: 
   - Translate Ecto schemas in `Ravner.Inventory` (e.g., `Brand`, `Organization`, `Project`) into Ash Resources.
   - Define basic CRUD actions (`create`, `read`, `update`, `destroy`) for each resource.
   - Configure the AshPostgres data layer to map to the existing database tables.
3. **Facade API**: Update the `Ravner.Inventory` context module to act as a facade. It will expose the exact same function signatures as before, but internally route calls to the new Ash Domains/Apis. This ensures zero disruption to the UI layer during migration.

### Phase 2: Centralized Authorization (Policies)
*Goal: Remove scattered `if role == :admin` checks from LiveViews and enforce rules at the data layer.*

1. **Define Actor**: Configure Ash to recognize the `Ravner.Accounts.User` (or Scope) as the system Actor.
2. **Implement Policies**: Add the `Ash.Policy.Authorizer` extension to Inventory resources.
   - Example: Only `:admin` can create Brands.
   - Example: A User can only read Projects they belong to (via `ProjectRole`).
3. **UI Cleanup**: Systematically remove manual role checks from `RavnerWeb.AdminLive.*` and rely on Ash to return `Ash.Error.Forbidden`. Use `AshPhoenix.Form` for robust error handling.

### Phase 3: Domain Lifecycle & Governance
*Goal: Bring domain ownership and state transitions under Ash governance.*

1. **Domain Resource (Partial)**: Convert the core `Ravner.Domains.Domain` schema to an Ash Resource.
2. **State Machines**: Use Ash Actions to model explicit state transitions for the domain lifecycle (e.g., `transition_to_deprecated`, `mark_as_abandoned`) rather than allowing raw updates.
3. **Audit Trails (AshPaperTrail)**: Add the `ash_paper_trail` extension to `Domain` and `DomainMetadata` (governance fields) to automatically record *who* changed *what* and *when*. This provides the history required for compliance officers.

### Phase 4: AshPhoenix Integration
*Goal: Leverage Ash's frontend tools for a cleaner, less repetitive UI codebase.*

1. **Forms**: Refactor LiveView forms (e.g., Domain editing, Project creation) to use `AshPhoenix.Form`. This automatically handles validation logic derived directly from the Ash Resource actions.
2. **Filtering/Sorting**: Adopt `AshPhoenix.FilterForm` in the `DomainLive.Index` view to replace the custom, complex Ecto query builder currently used for facets and searching.

## Risk Mitigation
- **Avoid Big Bang**: By maintaining the Context APIs as a facade (Phase 1), the frontend and backend can be decoupled during the migration.
- **Protect the Hot Path**: By keeping the `sync_*` functions and Oban workers on pure Ecto, we ensure that inserting 10,000 URLs during a Deep Tech scan doesn't incur the overhead of Ash validations or policies.