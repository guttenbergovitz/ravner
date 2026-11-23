# 6. Digital Landscape & Application Architecture Metamodel

Date: 2026-10-07

## Status
Accepted

## Context
Ravner currently tracks digital inventory via loosely coupled entities: Domains, Repositories, Projects, Organizations, and Brands. 

However, real-world digital ecosystems are structured around:
1.  **Value Streams** (strategic end-to-end customer and business value journeys: e.g. "Order to Cash", "Product Onboarding", "Support & Returns").
2.  **Regulatory & Compliance Drivers** (European Accessibility Act [EAA], NIS2 Directive, DORA, GDPR/RODO, Cyber Resilience Act [CRA]).
3.  **Business Capabilities** (what the business does: e.g. "Payment Processing", "PIM", "Identity & Access").
4.  **Architecture Constraints as Policy-as-Code** (declarative rules verified continuously by scanners: e.g. "VPN-only ingress", "EAA WCAG 2.1 AA", "EU data residency", "No public DB ports").
5.  **Applications** of canonical types (Websites, Storefronts, APIs, CMS, CRM, PIM, ERP, Portals, Workers, Integration Hubs).
6.  **Hosting Environments** (AWS, Cloudflare, Hetzner, Bare Metal) and **Managed Execution Platforms** (e.g. Gadget.dev, Supabase).
7.  **External Services & Data Pipelines** (e.g. Fivetran, Stripe, Auth0, Algolia).
8.  **Datastores** (PostgreSQL, Redis, MySQL, S3, MongoDB, Elasticsearch).
9.  **Domain Registrars** (Cloudflare, OVH, Route53, GoDaddy, Gandi, CSC Global).
10. **Network & VPN Access Boundaries** (Public Internet vs. Corporate VPN / WireGuard / Tailscale).

Currently, these relationships are either stored as unstructured string attributes (e.g. `Domain.hosting_platform`, `Domain.domain_registrar`) or completely absent. We need a cohesive, ADOIT/ArchiMate-compatible metamodel that connects these components into an easily navigable digital landscape and serves as triggers for Policy-as-Code enforcement against European regulatory mandates.

## Decision

We will implement a concrete Digital Landscape Metamodel in Ravner using Ash Framework under the `Ravner.Inventory` domain, adhering to the following structural decisions:

### 1. Introduce Strategic, Capability & Compliance Entities
*   **`ValueStream` (`Ravner.Inventory.ValueStream`):**
    *   Attributes: `name`, `slug`, `description`, `stage` (`:active`, `:proposed`, `:deprecated`), `criticality` (`:mission_critical`, `:operational`, `:supporting`).
    *   Relationships: `belongs_to :brand`, `many_to_many :applications`.
    *   Impact: Enables blast-radius analysis (incident on domain/datastore traces up to affected business stream).
*   **`BusinessCapability` (`Ravner.Inventory.BusinessCapability`):**
    *   Attributes: `name`, `category` (e.g. "Commerce", "Content", "Identity"), `description`.
    *   Relationships: `many_to_many :applications`.
    *   Impact: Uncovers application redundancy across brands and contractor agencies (Application Rationalization).
*   **`ArchitectureConstraint` as Policy-as-Code (`Ravner.Inventory.ArchitectureConstraint`):**
    *   Attributes: `category` (`:compliance_eaa`, `:compliance_nis2`, `:compliance_dora`, `:compliance_gdpr`, `:compliance_cra`, `:perimeter`, `:resilience`), `rule_type`, `enforcement_level` (`:mandatory`, `:advisory`), `compliance_status` (`:compliant`, `:violated`, `:unknown`), `parameters` (Map / JSONB), `last_evaluated_at`.
    *   Relationships: Attached to `Application`, `Domain`, and `Datastore`.
    *   Execution Trigger: Acts as **Policy-as-Code execution triggers** evaluated by Ravner's continuous scanners:
        *   **EAA:** `:eaa_accessibility_compliance` $\rightarrow$ verified by `Ravner.A11y` (`pa11y` / WCAG 2.1 AA).
        *   **NIS2:** `:nis2_supply_chain_governance`, `:nis2_incident_escalation_ready`, `:nis2_vulnerability_management`, `:nis2_cryptography_baseline`.
        *   **DORA:** `:dora_ict_third_party_register`, `:dora_disaster_recovery_redundancy`, `:dora_resilience_uptime_sla`.
        *   **GDPR:** `:gdpr_eu_data_residency` (ASN / region check), `:gdpr_no_exposed_datastores` (`PortProbe`), `:gdpr_no_exposed_backups` (`CuratedProbes`).
        *   **CRA:** `:cra_sbom_compliance` (`SbomSerializer` CycloneDX 1.5 JSON), `:no_plaintext_secrets` (`SecretsScanner`).
        *   **Perimeter:** `:vpn_only_ingress`, `:email_security_dmarc_enforced`, `:approved_registrars_only`.

### 2. Introduce `Application` as the Core Workload Entity
We will introduce `Ravner.Inventory.Application` as an Ash resource representing distinct digital systems:
*   **Canonical Application Types (`app_type`):**
    `:website`, `:storefront`, `:api`, `:cms`, `:crm`, `:pim`, `:erp`, `:portal`, `:worker`, `:integration_hub`.
*   **Lifecycle:** `:active`, `:in_development`, `:deprecated`, `:decommissioned`.
*   **Relationships:**
    *   `belongs_to :project` (inheriting ownership from `Organization` and `Brand`).
    *   `many_to_many :value_streams, Ravner.Inventory.ValueStream`.
    *   `many_to_many :capabilities, Ravner.Inventory.BusinessCapability`.
    *   `has_many :constraints, Ravner.Inventory.ArchitectureConstraint`.
    *   `has_many :domains, Ravner.Domains.Domain` (the application's entry points and public hostnames).
    *   `has_many :repositories, Ravner.Inventory.ProjectRepository` (the source code artifacts).
    *   `has_many :datastores, Ravner.Inventory.Datastore`.
    *   `belongs_to :hosting_environment, Ravner.Inventory.HostingEnvironment`.
    *   `belongs_to :network_access, Ravner.Inventory.NetworkAccess`.
    *   `has_many :external_services, Ravner.Inventory.ExternalService` (via integrations).

### 3. Introduce Supporting Infrastructure & Platform Resources
We will model infrastructure, external pipelines, and registrars as first-class entities:
1.  **`HostingEnvironment` (`Ravner.Inventory.HostingEnvironment`):**
    *   Attributes: `provider` (`:aws`, `:gcp`, `:cloudflare`, `:hetzner`, `:bare_metal`, `:saas_managed`), `environment_tier` (`:production`, `:staging`, `:development`), `region`.
2.  **`ExternalService` (`Ravner.Inventory.ExternalService`):**
    *   Attributes: `name`, `service_type` (`:managed_backend`, `:data_pipeline`, `:payment_gateway`, `:identity_provider`, `:search`), `url`.
    *   Covers managed platforms such as **Gadget.dev** (which may directly host application logic) and **Fivetran** (data pipeline syncing from datastores).
3.  **`Registrar` (`Ravner.Inventory.Registrar`):**
    *   Attributes: `name` (Cloudflare, OVH, Route53, GoDaddy, Gandi, CSC Global), `account_id`, `portal_url`.
    *   Replaces plain text `Domain.domain_registrar` with a structured relation: `Domain` belongs to `Registrar`.
4.  **`Datastore` (`Ravner.Inventory.Datastore`):**
    *   Attributes: `store_type` (`:postgresql`, `:mysql`, `:mariadb`, `:redis`, `:mongodb`, `:elasticsearch`, `:s3_bucket`, `:kafka`), `role` (`:primary_database`, `:cache`, `:object_storage`, `:search_index`).
    *   Belongs to an `Application` and/or `HostingEnvironment`.
5.  **`NetworkAccess` (`Ravner.Inventory.NetworkAccess`):**
    *   Attributes: `access_level` (`:public_internet`, `:vpn_restricted`, `:internal_vpc`, `:ip_allowlist`), `vpn_gateway_name` (e.g. WireGuard, Tailscale, Cloudflare Zero Trust, OpenVPN).
    *   Attached to `Application`s, `Domain`s, and `Datastore`s to explicitly govern security and ingress boundaries.

### 4. Refactor Existing Assets
*   **`Project`:** Add `project_type` (`:customer_facing`, `:internal_operations`, `:infrastructure`, `:integration`).
*   **`Domain`:** Add foreign keys `belongs_to :application, Ravner.Inventory.Application` and `belongs_to :registrar, Ravner.Inventory.Registrar`.
*   **`ProjectRepository`:** Add foreign key `belongs_to :application, Ravner.Inventory.Application`.
*   Retain transitive ownership: `Domain` $\rightarrow$ `Application` $\rightarrow$ `Project` $\rightarrow$ `Organization` (`:internal` vs. `:contractor`) $\rightarrow$ `Brand`.

### 5. Correlation with Automated Discovery (The Stop Line)
In accordance with `GEMINI.md`:
*   Runtime discovery workers (`TechFingerprint`, `PortProbe`, `ManifestParser`, `DnsRecord`, `A11yScanWorker`) remain pure Ecto/Oban jobs.
*   The landscape catalog leverages scan findings:
    *   `A11yScan` findings continuously evaluate `:eaa_accessibility_compliance`.
    *   `ContactResolver` escalations evaluate `:nis2_incident_escalation_ready`.
    *   `DomainMetadata.asn_org` correlates to `HostingEnvironment` and verifies `:gdpr_eu_data_residency`.
    *   `PortProbe` findings validate `NetworkAccess` and verify `:gdpr_no_exposed_datastores`.
    *   `CuratedProbes` verifies `:gdpr_no_exposed_backups` (`.env`, `dump.sql`).

### 6. Visualization & ADOIT Compatibility
*   **LiveView Visual Navigator:** Build an interactive Mermaid.js / SVG component in `OwnershipLive` and `DomainLive` rendering the full stack:
    `ValueStream > Capability > Brand > Org (Contractor) > Project > Application (Type) > [Domain (Registrar), Repo, Datastore (Fivetran), Hosting, ExternalService (Gadget.dev), VPN]`.
*   **ADOIT Exporter:** Expose `GET /export/archimate.xml` serializing the landscape to standard **ArchiMate 3.1 Model Exchange File Format (XML)**.

## Consequences

### Positive
*   **Comprehensive EU Compliance Engine:** Translates legal EU mandates (EAA, NIS2, DORA, GDPR, CRA) into continuous, automated verification checks.
*   **Policy-as-Code Integration:** Transforms architecture constraints from passive documentation into active, verifiable compliance triggers executed by background workers.
*   **Portfolio Rationalization:** Identifies tool duplication across organizations using Business Capabilities.
*   **Strategic Visibility:** Connects technical nodes all the way up to customer-facing Value Streams.
*   **Guaranteed Interoperability:** 100% compliant with ADOIT and Archi via ArchiMate 3.1 XML.

### Negative
*   Requires database migrations to introduce `value_streams`, `business_capabilities`, `architecture_constraints`, `applications`, `datastores`, `hosting_environments`, `registrars`, `external_services`, and `network_access` tables.
*   Requires a policy engine evaluation worker to map scan results to constraint compliance status.
