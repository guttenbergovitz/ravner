defmodule Ravner.Domains.AshDomain do
  @moduledoc """
  The Ash Domain for Domains entities.
  """
  use Ash.Domain,
    extensions: [AshPaperTrail.Domain]

  # authorization do
  #   authorize :always
  # end

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
end
