# Ash and Ecto Domain Boundaries

Ravner uses Ash for governance decisions and direct Ecto/Oban for high-volume
runtime work. The boundary is intentional and should be preserved when adding
features.

## Governance through Ash

These resources represent ownership, lifecycle, identity, or administrative
decisions:

- `Ravner.Accounts.UserResource`, invites, auth tokens, and API tokens
- `Ravner.Domains.Domain` lifecycle and ownership actions
- `Ravner.Inventory` organizations, projects, people, roles, applications,
  and related governance joins

Ash actions carry the actor, enforce `Ash.Policy.Authorizer` policies, and
create AshPaperTrail versions where the change is compliance relevant. Context
modules remain the stable public facade for callers.

## Runtime through Ecto and Oban

Scanners, command execution, worker orchestration, uptime checks, discovered
URLs, DNS records, technology evidence, CVE cache lookups, and notification
delivery stay on direct Ecto/Oban paths. These operations are high-volume or
external-I/O heavy and should not create one Ash changeset per observation.

Runtime writes may update scanner-maintained metadata, but they must not change
governance lifecycle or ownership fields through an unscoped Ecto update.

## Cross-domain rules

Relationships between `Domains`, `Inventory`, and `Accounts` are allowed for
read and authorization decisions. New write paths should cross the boundary
through a context facade and an explicit Ash action when the write changes
ownership, lifecycle, role, or audit history. Bulk ingestion may remain Ecto
when it only records technical evidence or scanner output.

When a new resource is introduced, decide its side of the boundary before
choosing its data layer, then add its actor and audit requirements to the
corresponding domain checklist.
