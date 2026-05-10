# Ash Framework Migration: Actionable Checklist

**Status:** Ready for Execution

This checklist translates the high-level Ash Migration Plan into trackable, concrete steps. It is designed to be followed sequentially to avoid regressions, maintain existing functionality ("Facade Pattern"), and provide clear rollback points.

---

## Pre-Migration Preparation
- [ ] Ensure all existing tests pass (`mix test`).
- [ ] Run `mix dialyzer` to capture a baseline of typespecs.
- [ ] Backup database schema (or ensure you have a fresh seed script).

---

## Phase 1: Foundation & Ash Installation
*Goal: Install dependencies and set up the basic Ash Domain without touching existing business logic.*

- [x] Add `ash`, `ash_postgres`, and `picosat` (for ID generation) to `mix.exs`.
- [x] Run `mix deps.get` and `mix deps.compile`.
- [x] Configure Ash in `config.exs` and `test.exs` (e.g., set up `Ash.Domain` registry).
- [x] Create `Ravner.Inventory.AshDomain` module.
- [x] Run `mix test` (Should pass cleanly; dependencies only).

---

## Phase 2: Inventory Entities (Facade Pattern)
*Goal: Map existing Ecto schemas in `Ravner.Inventory` to Ash Resources, using the current database tables. The UI still uses the old Ecto context.*

- [x] **Convert `Ravner.Inventory.Brand`**
  - [x] Create `Ravner.Inventory.Brand.Resource`.
  - [x] Define attributes matching the `brands` table.
  - [x] Add basic CRUD actions (`create`, `read`, `update`, `destroy`).
  - [x] Add `AshPostgres.DataLayer` mapping to `"brands"`.
- [x] **Convert `Ravner.Inventory.Organization`**
  - [x] Map to `"organizations"`.
  - [x] Define `belongs_to :brand` and `has_many :projects` relationships.
- [x] **Convert `Ravner.Inventory.Project`**
  - [x] Map to `"projects"`.
  - [x] Define relationships (`belongs_to :organization`).
- [x] **Convert Identity Entities**
  - [x] Convert `Ravner.Inventory.Person`.
  - [x] Convert `Ravner.Inventory.ProjectRole`.
- [x] **Refactor Context as Facade**
  - [x] Update `lib/ravner/inventory.ex` to delegate functions (e.g., `create_brand/1`) to `Ash.create!/2`.
  - [x] *Regression Check:* Run `mix test`. Existing UI and context tests MUST pass. If they fail, fix the Ash Resource definitions until the facade behaves identically to pure Ecto.

---

## Phase 3: Centralized Authorization (Policies)
*Goal: Move RBAC from the UI/Router layer down into Ash Policies.*

- [ ] Add `Ash.Policy.Authorizer` to all Inventory resources.
- [ ] Define the Actor (`Ravner.Accounts.User`).
- [ ] **Implement Policies on Resources:**
  - [ ] `Brand`: Only `:admin` can create/update/destroy. All authenticated users can read.
  - [ ] `Organization`: Only `:admin` or `:editor` can mutate.
  - [ ] `ProjectRole`: Restrict assignment based on user tier.
- [ ] **Context Updates for Actor:**
  - [ ] Update the `Ravner.Inventory` facade functions to accept an `actor` parameter (e.g., `create_brand(attrs, actor: user)`).
- [ ] **UI Cleanup:**
  - [ ] Remove `if @current_scope.user.role == :admin` guards around database writes in LiveViews.
  - [ ] Handle `Ash.Error.Forbidden` cleanly in the UI (flash messages).
- [ ] *Regression Check:* Run manual tests logging in as a `:viewer` to ensure mutation buttons either disappear (UI) or fail gracefully (Backend).

---

## Phase 4: Domain Lifecycle & Governance
*Goal: Bring domain metadata and lifecycle under Ash, enabling audit trails.*

- [ ] **Convert `Ravner.Domains.Domain` to Ash Resource.**
  - [ ] Map to `"domains"`.
  - [ ] Define relationships to `Brand`, `Organization`, `Project`.
- [ ] **State Machine Actions (Lifecycle):**
  - [ ] Replace `upsert_domain_metadata` lifecycle changes with explicit Ash actions on the Domain resource (e.g., `action :mark_deprecated`).
  - [ ] Implement action validations (e.g., "cannot mark a Priority domain as Abandoned without admin override").
- [ ] **Implement AshPaperTrail:**
  - [ ] Add `ash_paper_trail` dependency.
  - [ ] Generate PaperTrail migrations for `domains`.
  - [ ] Configure `Domain` resource to track history.
- [ ] *Regression Check:* Run `mix test`. Ensure that bulk operations (which hit the domains table) still function correctly. Ensure Oban dispatchers (which use Ecto) are NOT broken by the Ash Domain resource.

---

## Phase 5: UI Modernization (AshPhoenix)
*Goal: Replace custom Ecto form bindings with `AshPhoenix.Form`.*

- [ ] Add `ash_phoenix` dependency.
- [ ] **Refactor Forms:**
  - [ ] Update `RavnerWeb.AdminLive.BrandLive.FormComponent` to use `AshPhoenix.Form.for_create` and `for_update`.
  - [ ] Update Organization and Project forms.
- [ ] **Refactor Filtering (Optional but recommended):**
  - [ ] Replace custom Ecto query builders in `DomainLive.Index` with `AshPhoenix.FilterForm` for facet management.
- [ ] *Regression Check:* Verify all admin creation/edit forms render correctly and display validation errors directly from the Ash resources.

---

## Post-Migration Verification
- [ ] Verify the "Stop Line": Ensure `Ravner.SystemCommand`, `Ravner.Scans`, and `Ravner.Workers` still exclusively use `Ecto.Repo` and pure Elixir.
- [ ] Run full test suite.
- [ ] Run `mix dialyzer`.
- [ ] Perform a full end-to-end manual test: Add a Domain -> Assign to Project -> Run Scan -> Check Jobs Dashboard -> Verify Audit Trail.