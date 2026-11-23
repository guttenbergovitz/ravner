# Access Control & User Management

## Overview

Ravner implements a role-based access control (RBAC) model with three tiers:
Admin, Editor, and Viewer. Access is enforced at multiple layers: router pipelines,
LiveView `on_mount` hooks, Ash policies, and conditional UI rendering.

## Role Taxonomy

Ravner implements a two-class access control architecture (see [ADR 0002](../architecture/adr/0002-dual-tree-hierarchical-scoped-rbac.md)):

### 1. Global Technical-Administrative Roles (Admin-Managed Only)

Created and managed **exclusively by Administrator (`:admin`)** in `/admin/users` and `/admin/invites`. Scoped managers cannot create, edit, or escalate to global roles.

| Role | Scope | Description |
|------|-------|-------------|
| **`:admin`** | Global (Full) | Unrestricted system access, user management, global settings, integrations, and backup lifecycles. |
| **`:editor`** | Global (Technical) | Technical-administrative write access across **all** domains, repositories, projects, and organizations. Can trigger scans on any asset. |
| **`:viewer`** | Global (Auditor) | System-wide read-only access to all non-admin views. Cannot trigger scans or modify assets. |

### 2. Scoped Governance Roles (Dual-Tree Matrix Model)

Scoped roles isolate access strictly to assigned resources and their descendants. Managers have delegated authority to onboard subordinates within their branch.

#### Branch A: Client / Ownership Hierarchy (Client Tree)
- **`:brand_manager`**:
  - Scope: Assigned Brand(s) and all companies, projects, and domains beneath them.
  - Delegation: Creates client companies under their brand and appoints/invites **`:organization_manager`**.
  - Scans: Authorized for all domains in their brand portfolio.
- **`:organization_manager` (Company Manager)**:
  - Scope: Assigned Company and all projects and domains beneath it.
  - Delegation: Creates projects in their company and appoints/invites **`:product_owner`**.
  - Scans: Authorized for all domains in their company.
- **`:product_owner` (Product Owner / Business Owner)**:
  - Scope: Assigned projects and domains on the client side.
  - Responsibilities: Owns business lifecycle transitions, compliance tracking, and triggers scans for assigned domains.

#### Branch B: Delivery / Execution Hierarchy (Delivery Tree)
- **`:delivery_head` (Delivery Management)**:
  - Scope: Entire delivery branch across all projects, code repositories, and domains.
  - Delegation: Appoints/invites **`:pm_supervisor`** and **`:project_manager`**.
  - Scans: Authorized across all delivery projects.
- **`:pm_supervisor` (Team Lead / Supervisor)**:
  - Scope: Team of Project Managers (`supervisor_id`) and all projects/domains managed by them.
  - Delegation: Appoints/invites **`:project_manager`** into their supervised team.
- **`:project_manager` (PM)**:
  - Scope: Assigned projects cross-company, their connected repositories, and linked domains.
  - Responsibilities: Manages code repositories, VCS sync, SCA dependency CVE scans (OSV.dev), and triggers technical domain scans.

### 3. One-Time Login Links

Higher-tier managers (Admin, Delivery Head, Supervisor, Brand Manager, Company Manager) can generate a secure, 48-hour one-time login link (`/users/log-in/one-time/:token`) for their direct subordinates. This allows immediate onboarding or emergency password resets without requiring immediate SMTP delivery.

## Enforcement Layers

### 1. Router pipelines

- `:require_admin` — restricts `/admin/*` routes to admin users
- `:require_editor` — restricts governance CRUD routes to admin + editor users
- `:require_authenticated_user` — ensures a valid session exists

### 2. LiveView `on_mount`

- `:ensure_admin` — used in admin live_sessions
- `:ensure_editor` — used in governance live_sessions
- `:ensure_authenticated` — used in general authenticated live_sessions
- `:mount_current_scope` — assigns `@current_scope` for public pages

### 3. Template-level visibility

Conditional rendering hides interactive elements from unauthorized roles:

- Edit links in ownership views: visible only for `:admin` / `:editor`
- Scan action buttons: disabled for `:viewer` role
- Bulk discovery tools (Add domain, Import CSV, Scan visible): hidden for `:viewer`

### 4. Ash policies

Governance resources use `Ash.Policy.Authorizer` for write operations.
The router and Ash policies express the same access model.

### 5. Governance Audit Trail & Compliance (AshPaperTrail)

For SOC2, ISO 27001, and corporate compliance, governance-relevant mutations on assets and inventory structures are recorded in an append-only audit trail powered by `AshPaperTrail`:

- **Audited Resources & Versions**:
  - `Ravner.Domains.Domain`: Recorded into `domains_versions` via `AshPaperTrail.Domain` / `AshPaperTrail.Resource`.
  - `Ravner.Inventory.Brand`: Recorded into `brands_versions` via `AshPaperTrail.Resource`.
  - `Ravner.Inventory.Organization`: Recorded into `organizations_versions` via `AshPaperTrail.Resource`.
  - `Ravner.Inventory.Project`: Recorded into `projects_versions` via `AshPaperTrail.Resource`.

- **Audited Domain Events**:
  - `set_lifecycle`: All state transitions (e.g. `Active` -> `Deprecated` -> `Abandoned`).
  - `assign_brand`: Brand ownership assignment and changes.
  - `assign_organization`: Organization ownership assignment.
  - `assign_project`: Project ownership assignment.
  - `assign_contacts`: Project Manager (`pm_email`) and Product Owner (`po_email`) governance assignments.
  - `create`: Initial asset registration.
  - `update`: Changes to administrative metadata (repository URLs, hosting platform, delivery organization).

- **Domain Contacts & Project Team Integration**:
  - Explicit Ash action `:assign_contacts` ensures changes to PM and PO contacts are audited and governed by Ash policies (`:admin` and `:editor` only).
  - Contacts are linked with the `Ravner.Inventory.Person` directory via `Domains.find_person_by_email/1`.
  - Team members assigned to the domain's project via `Ravner.Inventory.ProjectRole` are automatically discovered as candidates via `Domains.project_team_candidates/1` (categorized into `:pm`, `:po`, and `:all`).
  - On the Domain Details page (`/domains/:id`), editors and admins can open the "Assign Contacts" modal with quick-pick chips populated from candidate project team members or enter custom email addresses.

- **Domain LiveView Timeline**:
  - Exposed directly on the domain details page (`/domains/:id`) under the **Governance Audit Trail** card.
  - Displays a vertical timeline connecting historical state transitions with human-readable entity labels, relative and absolute timestamps, and action badges.
  - Updates reactively in real time when an editor or admin mutates lifecycle, ownership, or contacts.

- **Querying Version History**:
  - `Ravner.Domains.list_domain_versions/1`
  - `Ravner.Inventory.list_brand_versions/1`
  - `Ravner.Inventory.list_organization_versions/1`
  - `Ravner.Inventory.list_project_versions/1`

### 6. 3-Tier Governance Escalation Hierarchy

To support incident response, vulnerability escalation, and ownership compliance across corporate structures, Ravner implements a 3-tier governance escalation ladder:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        GOVERNANCE ESCALATION LADDER                    │
├──────────────────────────┬─────────────────────────────────────────────┤
│ Level 1 · Operational    │ Project Manager (PM) & Product Owner (PO)   │
│                          │ Domain Contacts assigned from Project roles │
├──────────────────────────┼─────────────────────────────────────────────┤
│ Level 2 · Company / Org  │ Organization Manager (Person)               │
│                          │ Company/Entity Lead (`organization.manager`)│
├──────────────────────────┼─────────────────────────────────────────────┤
│ Level 3 · Executive / Brand Brand Manager (Person)                     │
│                          │ Executive Group Lead (`brand.brand_manager`)│
└──────────────────────────┴─────────────────────────────────────────────┘
```

- **Level 1 · Operational (Project)**:
  - First point of contact for operational alerts, vulnerability disclosures, and technical changes.
  - Derived from the domain's assigned Project Manager (`pm_email`) and Product Owner (`po_email`).
  - Automatically mapped to rich person profiles (`Ravner.Inventory.Person`) when matching emails exist in the organizational directory.
- **Level 2 · Company / Organization (`organization.manager`)**:
  - Designated managerial lead for the operating entity or subsidiary company.
  - Assigned via explicit Ash action `:assign_manager` on `Ravner.Inventory.Organization` and audited in `organizations_versions`.
  - Accessible via `Ravner.Inventory.assign_organization_manager/3`.
- **Level 3 · Executive / Brand (`brand.brand_manager`)**:
  - Executive or brand custodian overseeing the brand portfolio.
  - Assigned via explicit Ash action `:assign_brand_manager` on `Ravner.Inventory.Brand` and audited in `brands_versions`.
  - Accessible via `Ravner.Inventory.assign_brand_manager/3`.
- **Escalation Chain Resolver**:
  - `Ravner.Domains.domain_escalation_chain/1` constructs the normalized 3-tier hierarchy for any domain, resolving relations and gracefully handling unassigned tiers.
- **UI Surfaces**:
  - **Domain Details (`/domains/:id`)**: Dedicated **Governance Escalation Hierarchy** card displaying all three tiers with badges, names, direct mailto links, and directory navigation.
  - **Ownership Views (`/ownership`, `/ownership/brands/:id`, `/ownership/organizations/:id`)**: Displays designated managers with quick-access contact actions.
  - **Admin Forms (`/admin/brands`, `/admin/organizations`)**: Dropdown selectors populated from the `Person` directory for assignment by administrators.

## Authentication

### Active flag

Every user has a boolean `active` field. When set to `false`, the user is locked
out from all authentication paths:

- `get_user_by_email_and_password/2` — checks `user.active` before verifying password
- `get_user_by_session_token/1` — pattern matches on `%User{active: true}`
- `login_user_by_magic_link/1` — returns `{:error, :inactive}` for deactivated accounts

### Session controller handling

The `UserSessionController` handles the `:inactive` error by displaying:
"Your account has been deactivated. Please contact an administrator."

## Admin User Management

Available at `/admin/users` (admin-only).

### Create user

- Fields: email, name, role, temporary password
- Auto-confirms the account (no email verification needed)
- Creates both the Ecto record and Ash resource

### Edit user

- Changeable: role, name, active flag
- Uses `User.role_changeset/2` for validation

### Password reset (admin-initiated)

Three options:

1. **Token link** — Generates a `reset_password` token (valid 1 day), emails a link to
   `/users/reset-password/:token`. User sets their own new password.
2. **Random password** — Generates a 16-char random password, updates the user, emails the
   new password. All existing sessions are invalidated.
3. **Manual entry** — Admin sets a specific password directly. Sessions invalidated.

### Delete user

Safeguards:
- Cannot delete your own account
- Cannot delete the last admin user

Implementation delegates to Ash for destroy (respects policies and audit trail).

## Password Reset Flow (Public)

Route: `GET /users/reset-password/:token` → `UserResetPasswordController`

1. Admin triggers token generation from the admin panel
2. User receives email with reset link
3. Controller validates token, renders password form
4. On submit, password is updated and all tokens are deleted
5. User is redirected to login

Token validity: 1 day (`@reset_password_validity_in_days` in `UserToken`).
