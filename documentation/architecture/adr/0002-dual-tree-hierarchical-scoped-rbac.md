# ADR 0002: Dual-Tree Hierarchical Scoped RBAC & Technical Administrative Roles

**Status:** Accepted  
**Deciders:** Core Engineering Team  

---

## 1. Context and Problem Statement

Ravner historically operated with a flat three-tier authorization model: `:admin`, `:editor`, and `:viewer`.

While this model served early development, it breaks down in multi-company and enterprise environments for three fundamental reasons:

1. **Lack of Resource Scoping**:
   An `:editor` had unrestricted write and scan execution permissions across **all** domains, code repositories, brands, and companies in the entire database. A project manager working for Client A could view, edit, and trigger intrusive scans on Client B's infrastructure.
2. **Two Separate Organizational Trees (Client Ownership vs. Delivery Execution)**:
   In modern corporate and agency structures, there are two distinct hierarchies that intersect at the project level:
   - **Client / Ownership Tree**: Brands own client companies; client companies employ **Product Owners (POs)** who own business requirements, compliance acceptance, and domain lifecycle states.
   - **Delivery / Agency Tree**: Delivery Management employs **Supervisors** and **Project Managers (PMs)**. PMs operate **cross-company** (managing projects across multiple client entities) and report up an internal delivery chain, not to client company management.
3. **Delegated Administration & Access Onboarding**:
   Higher-tier managers (Brand Managers, Company Managers, Delivery Leads) lacked the ability to onboard or manage their own team members without requiring full system admin intervention. Furthermore, without integrated one-time login links, onboarding users without relying on immediate email delivery was cumbersome.

We need an architectural authorization model that enforces strict resource isolation, models both Client and Delivery trees naturally, preserves global technical administrative workflows, and honors Ravner's **Stop Line** rule (Ash for governance, pure Ecto/Oban for runtime paths).

---

## 2. Decision Drivers

* **KISS Principle**: Keep the model simple, robust, and functional. Avoid over-abstracted role permission graphs or micro-permission tables.
* **Strict Least-Privilege & Data Isolation**: Users in scoped roles must only see and trigger tests/scans for resources within their active scope.
* **Stop Line Compliance**: Centralize governance writes and authorization policies in **Ash Framework** (`Ash.Policy.Authorizer`), while keeping high-volume domain listings and scan execution paths on fast pure Ecto queries parameterized by actor `Scope`.
* **Dual-Tree Representation**:
  - Client Tree: Brand Manager ➔ Company Manager ➔ Product Owner (PO).
  - Delivery Tree: Delivery Head ➔ Supervisor ➔ Project Manager (PM, cross-company).
* **Preservation of Global Technical Roles**: Preserve `:admin`, `:editor`, and `:viewer` as global, cross-system roles created and managed exclusively by `:admin`. `:editor` retains full technical-administrative access to all assets.
* **Delegated Onboarding**: Allow higher-tier managers to generate one-time login links (magic links) for their subordinates to allow immediate login and password configuration.

---

## 3. Considered Options

* **Option 1: Dynamic Permission Matrix (RBAC + ABAC micro-permissions table)**  
  Store individual granular permissions (`can_scan_domain_123`, `can_edit_repo_456`) in relational permission join tables.  
  *Drawback*: High complexity, complex permission sync, difficult caching, excessive database queries on every page load.
* **Option 2: Single Strict Hierarchy (Brand ➔ Company ➔ Project)**  
  Force all users into a single tree where PMs belong strictly to a single client company.  
  *Drawback*: Incompatible with reality — PMs are delivery team members who regularly run projects across multiple client companies simultaneously.
* **Option 3: Dual-Tree Hierarchical Scoped RBAC with Global Technical Roles (Selected)**  
  Separate global technical-administrative roles from scoped governance roles. Model two distinct organizational trees (Client Tree and Delivery Tree) that converge at the Project/Domain asset level, with an efficient functional `ScopeResolver` computing accessible resource IDs for every request.

---

## 4. Decision Outcome

**Chosen Option: Option 3 — Dual-Tree Hierarchical Scoped RBAC.**

### Architectural Model

```
GLOBAL TECHNICAL ROLES (Managed ONLY by Admin)
├── :admin   (Full system control, users, integrations, backups, all assets)
├── :editor  (Global technical-administrative access to all domains, repos, and scans)
└── :viewer  (Global read-only access to all assets, cannot run scans or edit)

CLIENT HIERARCHY (Ownership)                 DELIVERY HIERARCHY (Execution)
================================             ==============================
:brand_manager (Brand Portfolio)             :delivery_head (Delivery Management)
       │                                                    │
       ▼                                                    ▼
:organization_manager (Company)              :pm_supervisor (Team Lead)
       │                                                    │
       ▼                                                    ▼
:product_owner (Business Owner)              :project_manager (PM, cross-company)
       \                                                   /
        \                                                 /
         ▼                                               ▼
          ───────────────────────────────────────────────
                         PROJECT / DOMAIN
          ───────────────────────────────────────────────
          • Repositories (VCS Bitbucket/GitHub/GitLab)
          • Dependencies & SCA Vulnerabilities (OSV.dev)
          • Security, A11y, Lighthouse, DNS, Uptime Scans
          • Domain Lifecycle & Business Metadata
```

---

## 5. Technical Specification

### 1. Role Definitions & Classes

#### Class 1: Global Technical-Administrative Roles (Admin-Managed Only)
- **`:admin`**: Unrestricted system-wide control. The only role authorized to create or edit `:admin`, `:editor`, and `:viewer`.
- **`:editor`**: Global technical-administrative role with write and scan access across all domains, repositories, projects, and organizations.
- **`:viewer`**: Global auditor with read-only access across the entire inventory.

#### Class 2: Scoped Governance Roles (Cascading Delegation)
- **`:brand_manager`**:
  - Scope: Assigned brands, and all companies, projects, and domains beneath them.
  - Delegation: Can create companies under their brands and appoint/invite `:organization_manager`.
- **`:organization_manager` (Company Manager)**:
  - Scope: Assigned company, and all projects and domains beneath it.
  - Delegation: Can create projects under their company and appoint/invite `:product_owner`.
- **`:product_owner` (PO / Business Owner)**:
  - Scope: Assigned client projects and domains.
  - Responsibilities: Owns business lifecycle state transitions, compliance tracking, and triggers domain security tests.
- **`:delivery_head`**:
  - Scope: Entire delivery branch across all projects, repositories, and domains.
  - Delegation: Can appoint/invite `:pm_supervisor` and `:project_manager`.
- **`:pm_supervisor`**:
  - Scope: Projects and domains managed by their team of PMs (`supervisor_id`).
  - Delegation: Can appoint/invite `:project_manager` into their supervised team.
- **`:project_manager` (PM)**:
  - Scope: Assigned projects cross-company, their connected repositories, and linked domains.
  - Responsibilities: Manages code repositories, VCS sync, SCA dependency CVE scans, and triggers technical domain scans.

### 2. User & Person Model Unification
- `people` table receives `user_id` (unique foreign key referencing `users.id`, nullable).
- `users` table receives `supervisor_id` (foreign key referencing `users.id`, nullable).
- Contact management in `Ravner.Inventory.Person` directly links to authentication identity in `Ravner.Accounts.User`.

### 3. Functional Scope Engine (`Ravner.Accounts.ScopeResolver`)
- Evaluates the actor on mount into a lightweight `Ravner.Accounts.Scope` struct:
  - For `:admin` and `:editor`: `global?: true, admin?: ..., editor?: true`. Unrestricted queries.
  - For `:viewer`: `global?: true, viewer?: true`. Read-only queries.
  - For scoped roles: Precomputes `brand_ids`, `organization_ids`, `project_ids`, `domain_ids`, and `supervised_pm_ids`.
- Provides fast guard predicates:
  - `can_view_domain?(scope, domain_id)`
  - `can_scan_domain?(scope, domain_id)`
  - `can_manage_project?(scope, project_id)`
  - `can_delegate_role?(actor_scope, target_role, context)`

### 4. Stop Line Governance & Policies
- **Ash Layer (`Ash.Policy.Authorizer`)**:
  - `Organization`, `Project`, `ProjectRole`, `Domain`, and `UserInviteResource` enforce policy checks verifying the actor is either `:admin`, `:editor`, or has direct management authority over the resource's hierarchy.
- **Runtime Layer (Pure Ecto / Oban)**:
  - `Domains.list_domains/2` automatically applies `where: d.id in ^scope.domain_ids` for scoped users.
  - Unassigned orphan assets are strictly filtered to `:admin` and `:editor`.
  - Scan runners (`SecurityRunner`, `RepoScanner`) verify `can_scan_domain?` / `can_scan_repo?` before initiating jobs.

### 5. One-Time Login Link
- A higher-tier manager or admin can generate a secure, 48-hour one-time login token for their subordinates:
  - `Admin` ➔ Any user
  - `Delivery Head` ➔ Supervisors and PMs
  - `Supervisor` ➔ Team PMs
  - `Brand Manager` ➔ Company Managers
  - `Company Manager` ➔ Product Owners
- URL format: `https://app/users/log-in/one-time/:token`.
- Visiting the link logs the user in and immediately displays the password update interface.
