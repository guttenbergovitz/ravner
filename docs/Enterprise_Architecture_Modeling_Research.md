# Digital Landscape & Application Architecture in Ravner

## 1. The Core Problem: Beyond Flat Inventory
Until now, Ravner has tracked digital assets primarily as flat, loosely coupled records:
* Domains (with basic technical status and string fields for hosting and registrar)
* Repositories (git URLs and code scans)
* Projects, Organizations, and Brands (ownership containers)

In reality, digital estates do not operate as disconnected domains and git repos. A digital landscape is organized around:
1. **Business Strategy & Value Streams** (end-to-end business journeys: "Order to Cash", "Product Enrichment", "Customer Support")
2. **Regulatory & Policy-as-Code Constraints** (EU directives: EAA, NIS2, DORA, GDPR, CRA continuously evaluated by scanners)
3. **Business Capabilities** (what the business does: "Payment Processing", "PIM", "Identity & Access")
4. **Applications** of canonical types (Websites, Stores, CMS, CRM, PIM, APIs, Integrations)
5. **Hosting Environments & Managed Platforms** (AWS, Cloudflare, Bare Metal, or managed backend platforms like **Gadget.dev**)
6. **External Services & Data Pipelines** (SaaS tools, payment gateways, or ETL services like **Fivetran**)
7. **Datastores** (PostgreSQL, Redis, MySQL, S3)
8. **Domain Registrars** (Cloudflare, GoDaddy, OVH, Route53, CSC)
9. **Network & VPN boundaries** (Public internet vs. WireGuard, Tailscale, Cloudflare Zero Trust)

---

## 2. The Target Landscape Metamodel

```
┌───────────────────────────────────────────────────────────────────────────┐
│ STRATEGY, GOVERNANCE & REGULATORY COMPLIANCE (ArchiMate 3.1)              │
│  [ValueStream] ───────── groups ────────> [BusinessCapability]            │
│  ("Order to Cash")                        ("Payment Processing", "PIM")   │
│                                                     │                     │
│  [ArchitectureConstraint] (Policy-as-Code) ────────┤                      │
│   ├── European Accessibility Act (EAA / WCAG 2.1 AA)│                      │
│   ├── NIS2 Directive (Cyber Hygiene & Supply Chain) │                      │
│   ├── DORA (ICT Third-Party Register & Resilience)  │                      │
│   ├── GDPR / RODO (Data Residency & Privacy)        │                      │
│   └── Cyber Resilience Act (CRA / CycloneDX SBOM)   │                      │
└─────────────────────────────────────────────────────┼─────────────────────┘
                                                      │ realized by
┌─────────────────────────────────────────────────────▼─────────────────────┐
│ BUSINESS & OWNERSHIP                                                      │
│  [Brand] ──> [Organization] (:internal / :contractor) ──> [Project]       │
└─────────────────────────────────────┬─────────────────────────────────────┘
                                      │ delivers / owns
┌─────────────────────────────────────▼─────────────────────────────────────┐
│ APPLICATION (The Core System)                                             │
│  [Application]                                                            │
│   - canonical_type: :website | :storefront | :api | :cms | :crm | :pim    │
│                     :erp | :portal | :worker | :integration_hub           │
│   - lifecycle: :active | :in_development | :deprecated | :decommissioned  │
└──────┬────────────┬─────────────┬─────────────┬─────────────┬─────────────┘
       │            │             │             │             │
┌──────▼──────┐ ┌───▼───────┐ ┌───▼───────┐ ┌───▼───────┐ ┌───▼───────────┐
│ [Domain]    │ │[Repository│ │[Datastore]│ │[HostingEnv│ │[External     │
│ - apex/sub  │ │ - git url │ │ - postgres│ │ - AWS/GCP │ │  Service]     │
│ - DNS/cert  │ │ - SBOM    │ │ - redis/s3│ │ - Hetzner │ │ - gadget.dev  │
│      │      │ └───────────┘ │ - mysql/es│ │ - on-prem │ │ - fivetran    │
│      ▼      │               └─────┬─────┘ └─────┬─────┘ │ - stripe/auth0│
│ [Registrar] │                     │             │       └───────────────┘
│ - Cloudflare│                     └──────┬──────┘
│ - OVH / AWS │                            │
└─────────────┘                ┌───────────▼────────────────────────┐
                               │ NETWORK & ACCESS BOUNDARY          │
                               │  [NetworkAccess / VPN]             │
                               │  - :public_internet                │
                               │  - :vpn_restricted (WireGuard)     │
                               │  - :internal_vpc                   │
                               └────────────────────────────────────┘
```

---

## 3. Regulatory Alignment: Closed Constraint Taxonomy

Ravner's scanners map directly into European and international regulatory compliance frameworks. Constraints are categorized by dimension and regulatory driver:

### 3.1. European Accessibility Act (EAA / EN 301 549 / WCAG 2.1 AA)
*   **Driver:** Mandatory EU directive for e-commerce, consumer web apps, banking, and public portals.
*   **Constraint:** `:eaa_accessibility_compliance`
*   **Verification:** Ravner's native `Ravner.A11y` (`pa11y` + Chromium / axe-core) evaluates homepage and key flows. Flags non-compliance if WCAG 2.1 AA violations $> 0$.

### 3.2. NIS2 Directive (Network and Information Security 2)
*   **Driver:** EU cybersecurity directive requiring risk management, supply chain security, cyber hygiene, and strict incident response.
*   **Constraints:**
    *   `:nis2_supply_chain_governance`: Verifies that contractor organizations (`Organization.type == :contractor`) have assigned delivery managers, clear RACI ownership in `ProjectRole`, and audited VCS repositories.
    *   `:nis2_incident_escalation_ready`: Evaluates `Ravner.Domains.ContactResolver` to guarantee an unbroken 3-level escalation chain (PM/PO $\rightarrow$ Org Manager $\rightarrow$ Brand Manager) for mandatory 24-hour incident notification.
    *   `:nis2_vulnerability_management`: Evaluates Google OSV scanner findings across lockfiles, flagging unpatched high/critical vulnerabilities.
    *   `:nis2_cryptography_baseline`: Evaluates `TlsHeaderAudit` (HSTS enabled, TLS 1.2/1.3, SSL certificate validity $> 30$ days).

### 3.3. DORA (Digital Operational Resilience Act)
*   **Driver:** EU regulation requiring financial entities and critical ICT third parties to maintain comprehensive ICT risk registers and operational continuity.
*   **Constraints:**
    *   `:dora_ict_third_party_register`: Requires every critical application to map its `HostingEnvironment` (AWS/Hetzner), its managed platforms (e.g. `gadget.dev`), its data pipelines (e.g. `fivetran`), and third-party SaaS dependencies.
    *   `:dora_disaster_recovery_redundancy`: Validates multi-region hosting or DR fallback environments.
    *   `:dora_resilience_uptime_sla`: Enforces minimum uptime ratios via Ravner's continuous `Uptime` check workers.

### 3.4. GDPR / RODO (General Data Protection Regulation)
*   **Driver:** Data protection by design, confidentiality, and international data transfer restrictions (Schrems II).
*   **Constraints:**
    *   `:gdpr_eu_data_residency`: Skaner ASN (`DomainMetadata.asn_org`) and `HostingEnvironment.region` verify that personal data hosting remains within the EU/EEA.
    *   `:gdpr_no_exposed_datastores`: `PortProbe` verifies that production datastore ports (5432, 3306, 6379, 27017, 9200) are completely inaccessible from the public internet.
    *   `:gdpr_no_exposed_backups`: `CuratedProbes` verifies that `.env`, `wp-config.php`, `dump.sql`, and `backup.sql` files are not exposed on public web roots.

### 3.5. Cyber Resilience Act (CRA) & Supply Chain Security
*   **Driver:** EU regulation mandating Software Bill of Materials (SBOM) and vulnerability handling for software products.
*   **Constraints:**
    *   `:cra_sbom_compliance`: Verifies that `Ravner.Scans.SbomSerializer` successfully exports valid **CycloneDX 1.5 JSON** with package URLs (`purl`) for all repository manifests.
    *   `:no_plaintext_secrets`: Verifies via `SecretsScanner` that API keys, tokens, and database URIs are never committed into git repositories.

### 3.6. Perimeter & Domain Identity Hygiene
*   **Constraints:**
    *   `:email_security_dmarc_enforced`: Verifies SPF, DKIM, and DMARC `reject` or `quarantine` policy on brand apex domains to prevent phishing.
    *   `:approved_registrars_only`: Verifies that domain registration belongs to corporate-managed accounts (`Registrar`).
    *   `:vpn_only_ingress`: Verifies that administrative backoffices and internal portals are not reachable outside VPN/Zero-Trust tunnels.

---

## 4. Entity Breakdown

### 4.1. Value Streams (`Ravner.Inventory.ValueStream`)
Connects the technical IT landscape to executive business impact:
*   **Purpose:** Groups applications according to end-to-end customer and business outcomes (e.g., *"E-Commerce Order to Cash"*, *"Product Onboarding & Enrichment"*, *"B2B Partner Invoicing"*, *"Customer Support & Returns"*).
*   **Attributes:** `name`, `slug`, `description`, `stage` (`:active`, `:proposed`, `:deprecated`), `criticality` (`:mission_critical`, `:operational`, `:supporting`).
*   **Relationships:**
    *   `belongs_to :brand` (or global)
    *   `belongs_to :business_owner, Ravner.Inventory.Person`
    *   `many_to_many :applications, Ravner.Inventory.Application`

### 4.2. Business Capabilities (`Ravner.Inventory.BusinessCapability`)
Represents modular abilities possessed by the enterprise (ArchiMate `Capability`):
*   **Purpose:** Defines *what* the business does, independent of individual organizational units or implementation technologies (e.g., *"Payment Processing"*, *"Product Information Management"*, *"Identity & Access Management"*, *"Content Management"*, *"Data Pipeline & ETL"*).
*   **Portfolio Rationalization:** Identifies tool redundancy across brands and contractors.
*   **Relationships:**
    *   `many_to_many :applications, Ravner.Inventory.Application`
    *   `many_to_many :value_streams, Ravner.Inventory.ValueStream`

### 4.3. Architecture Constraints as Policy-as-Code (`Ravner.Inventory.ArchitectureConstraint`)
ArchiMate `Constraint` / `Principle` translated into **executable verification triggers**:
*   **Attributes:**
    *   `category`: `:compliance_eaa`, `:compliance_nis2`, `:compliance_dora`, `:compliance_gdpr`, `:perimeter`, `:supply_chain`, `:resilience`.
    *   `rule_type`: (The closed taxonomy described in Section 3).
    *   `enforcement_level`: `:mandatory`, `:advisory`.
    *   `compliance_status`: `:compliant`, `:violated`, `:unknown`.
    *   `parameters`: Map / JSONB for fine-tuning thresholds.
    *   `last_evaluated_at`: DateTime.
*   **Relationships:** Attached to `Application`, `Domain`, and `Datastore`.

### 4.4. Application (`Ravner.Inventory.Application`)
The central architectural unit. Represents a functional software application or service.
*   **Canonical Types (`app_type`):**
    *   `:website`, `:storefront`, `:api`, `:cms`, `:crm`, `:pim`, `:erp`, `:portal`, `:worker`, `:integration_hub`.
*   **Attributes:** `name`, `slug`, `app_type`, `lifecycle_state`, `criticality` (`:mission_critical`, `:operational`, `:low`), `notes`.
*   **Relationships:**
    *   `belongs_to :project`
    *   `many_to_many :value_streams, Ravner.Inventory.ValueStream`
    *   `many_to_many :capabilities, Ravner.Inventory.BusinessCapability`
    *   `has_many :constraints, Ravner.Inventory.ArchitectureConstraint`
    *   `has_many :domains`
    *   `has_many :repositories` (`ProjectRepository`)
    *   `has_many :datastores`
    *   `belongs_to :hosting_environment`
    *   `belongs_to :network_access`
    *   `has_many :external_services` (through integrations)

### 4.5. External Services & Managed Platforms (`Ravner.Inventory.ExternalService`)
Represents external platforms, managed SaaS tools, or serverless execution platforms:
*   **Platform Types (`service_type`):**
    *   `:managed_backend` (e.g. **Gadget.dev**, Supabase, Firebase)
    *   `:data_pipeline` (e.g. **Fivetran**, Airbyte, Segment)
    *   `:payment_gateway` (e.g. Stripe, Adyen, PayPal)
    *   `:identity_provider` (e.g. Auth0, Okta, Clerk)
    *   `:search_engine` (e.g. Algolia, Meilisearch)
    *   `:communication` (e.g. SendGrid, Twilio, Mailgun)

### 4.6. Domain Registrars (`Ravner.Inventory.Registrar`)
Elevates registrars from plain strings into a first-class inventory entity:
*   **Attributes:** `name` (e.g. Cloudflare Registrar, OVH, Route53, GoDaddy, Domeny.pl, Gandi, CSC Global), `account_id`, `portal_url`, `notes`.
*   **Relationship:** `Domain` belongs to `Registrar`.

### 4.7. Hosting Environment (`Ravner.Inventory.HostingEnvironment`)
Represents the infrastructure cloud, cluster, or platform where workloads reside:
*   **Provider / Platform:** `:aws`, `:gcp`, `:azure`, `:cloudflare`, `:hetzner`, `:ovh`, `:bare_metal`, `:saas_managed`.
*   **Tier / Environment:** `:production`, `:staging`, `:development`, `:dr`.
*   **Region:** e.g., `eu-central-1`, `us-east-1`, `on-premise-dc1`.

### 4.8. Datastores (`Ravner.Inventory.Datastore`)
Represents persistent data stores, caches, and storage services:
*   **Datastore Types (`store_type`):**
    *   `:postgresql`, `:mysql`, `:mariadb`, `:redis`, `:mongodb`, `:elasticsearch`, `:s3_bucket`, `:kafka`.

### 4.9. Network & Access Boundaries (`Ravner.Inventory.NetworkAccess`)
Classifies ingress and connectivity security:
*   **Access Profiles:**
    *   `:public_internet`, `:vpn_restricted` (WireGuard, Tailscale), `:internal_vpc`, `:ip_allowlist`.

---

## 5. Visual UML-like Navigation & Exporters

### 5.1. LiveView Interactive Diagram (Mermaid / SVG)
*   Rendered dynamically per Value Stream, Application, or Project.
*   Compliance status icons render next to nodes (e.g., green shield for verified EAA/NIS2/VPN constraints; red warning badge for violations).

### 5.2. ADOIT & ArchiMate 3.1 Exporter
*   Direct export to **ArchiMate 3.1 Model Exchange File Format (XML)**.
*   Imports cleanly into ADOIT, Archi, and enterprise GRC tools.
*   Endpoint: `GET /projects/:project_id/export/archimate`.

---

## 6. Implementation Status & User Workflows (v0.16.0)

### 6.1. Navigation & Asset Discovery
*   **Top Navigation Reorganization:**
    *   **Inventory:** Quick access to Domains (`/domains`), Applications (`/ownership/landscape`), and Repositories (`/admin/repositories`).
    *   **Governance:** Architecture Landscape (`/ownership/landscape`), Brands & Orgs (`/ownership`), and Delivery Hierarchy (`/ownership/delivery`).
    *   **Admin:** Focused on users, invites, breach findings, certificates, jobs, and telemetry.

### 6.2. Application Management Hub (`/ownership/applications/:id`)
*   **Overview & Topology:** Inspect infrastructure hosting nodes, network perimeters, and regulatory notes.
*   **Domain Management:** Attach/detach active or scanned domain endpoints with live search filtering.
*   **Datastores:** Provision database nodes (PostgreSQL, Redis, MySQL, S3, MongoDB, Elasticsearch) with operational roles (primary, read replica, cache, search index).
*   **External Services:** Link third-party SaaS/PaaS vendors (e.g. Stripe, Gadget.dev, Fivetran) to track supplier supply chain risks (NIS2 / DORA).
*   **Policy Constraints:** Record and evaluate regulatory mandates (European Accessibility Act / WCAG 2.1 AA, NIS2, DORA, GDPR).
*   **Audit Trail:** Immutable ledger of revisions via `AshPaperTrail`.

