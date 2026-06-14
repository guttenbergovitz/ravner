# Access Control & User Management

## Overview

Ravner implements a role-based access control (RBAC) model with three tiers:
Admin, Editor, and Viewer. Access is enforced at multiple layers: router pipelines,
LiveView `on_mount` hooks, Ash policies, and conditional UI rendering.

## Roles

| Role | Scope |
|------|-------|
| Admin | Full system access including user management, settings, and destructive actions |
| Editor | Governance CRUD (organizations, projects, people, brands), domain management, scan triggers |
| Viewer | Read-only access to all non-admin views |

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
