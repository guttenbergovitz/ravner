defmodule Ravner.Domains.AshDomain do
  @moduledoc """
  The Ash Domain for Domains entities.
  """
  use Ash.Domain,
    extensions: [AshPaperTrail.Domain, AshAi, AshJsonApi.Domain]

  authorization do
    authorize(:by_default)
  end

  paper_trail do
    include_versions?(true)
  end

  resources do
    resource(Ravner.Domains.Domain)
    resource(Ravner.Domains.DomainTag)
    resource(Ravner.Domains.DnsRecord)
    resource(Ravner.Domains.TechEvidence)
    resource(Ravner.Domains.DiscoveredUrl)
    resource(Ravner.Domains.DomainMetadata)
  end

  tools do
    tool(:list_domains, Ravner.Domains.Domain, :read,
      select: [
        :id,
        :name,
        :type,
        :lifecycle_state,
        :technical_status,
        :pm_email,
        :po_email,
        :project_id,
        :brand_id,
        :organization_id
      ],
      description:
        "List discovered domains and subdomains with governance lifecycle and technical status"
    )

    tool(:get_domain, Ravner.Domains.Domain, :read,
      get_by: :id,
      select: [
        :id,
        :name,
        :type,
        :lifecycle_state,
        :technical_status,
        :pm_email,
        :po_email,
        :delivery_organization,
        :hosting_platform,
        :domain_registrar,
        :repository_url,
        :project_id,
        :brand_id,
        :organization_id
      ],
      description: "Get domain details by domain ID"
    )

    tool(:get_domain_by_name, Ravner.Domains.Domain, :read,
      get_by: :name,
      select: [
        :id,
        :name,
        :type,
        :lifecycle_state,
        :technical_status,
        :pm_email,
        :po_email,
        :delivery_organization,
        :hosting_platform,
        :domain_registrar,
        :repository_url,
        :project_id,
        :brand_id,
        :organization_id
      ],
      description: "Get domain details by exact domain name"
    )

    tool(:set_domain_lifecycle, Ravner.Domains.Domain, :set_lifecycle,
      select: [:id, :name, :lifecycle_state, :updated_at],
      description:
        "Update the lifecycle state of a domain (priority, active, under_review, placeholder, deprecated, decommissioned, abandoned)"
    )

    tool(:assign_domain_project, Ravner.Domains.Domain, :assign_project,
      select: [:id, :name, :project_id, :brand_id, :organization_id],
      description: "Assign a domain to a project, brand, and/or organization"
    )

    tool(:assign_domain_contacts, Ravner.Domains.Domain, :assign_contacts,
      select: [:id, :name, :pm_email, :po_email],
      description: "Assign PM and PO contact emails to a domain"
    )

    tool(:list_domain_dns_records, Ravner.Domains.DnsRecord, :read,
      select: [:id, :domain_id, :type, :value, :ttl],
      description: "List DNS records for domains (governance view)"
    )

    tool(:list_domain_tech_evidence, Ravner.Domains.TechEvidence, :read,
      select: [:id, :domain_id, :name, :version, :source, :confidence],
      description: "List detected web technologies and evidence for domains (governance view)"
    )
  end
end
