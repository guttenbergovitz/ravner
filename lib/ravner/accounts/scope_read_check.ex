defmodule Ravner.Accounts.ScopeReadCheck do
  @moduledoc """
  Ash filter check that limits governance reads to the actor's resolved scope.

  Global actors keep unrestricted read access. Scoped actors are limited by the
  ownership identifiers resolved by `Ravner.Accounts.ScopeResolver`.
  """

  use Ash.Policy.FilterCheck

  alias Ravner.Accounts.{Scope, User}

  alias Ravner.Domains.{
    DiscoveredUrl,
    DnsRecord,
    Domain,
    DomainMetadata,
    DomainTag,
    TechEvidence
  }

  alias Ravner.Inventory

  @impl true
  def describe(_opts), do: "actor can read records in the resolved governance scope"

  @impl true
  def filter(nil, _context, _opts), do: false

  def filter(%Scope{} = scope, %{resource: resource}, _opts) do
    if scope.global? do
      true
    else
      resource_filter(resource, scope)
    end
  end

  def filter(%User{} = actor, context, opts) do
    filter(Scope.for_user(actor), context, opts)
  end

  def filter(%{role: role}, _context, _opts) when role in [:admin, :editor, :viewer], do: true

  def filter(_actor, _context, _opts), do: false

  defp resource_filter(Domain, %Scope{domain_ids: ids}), do: expr(id in ^ids)

  defp resource_filter(resource, %Scope{domain_ids: ids})
       when resource in [
              DnsRecord,
              TechEvidence,
              DiscoveredUrl,
              DomainTag,
              DomainMetadata
            ],
       do: expr(domain_id in ^ids)

  defp resource_filter(Inventory.Brand, %Scope{brand_ids: ids}), do: expr(id in ^ids)

  defp resource_filter(Inventory.Organization, %Scope{organization_ids: ids}),
    do: expr(id in ^ids)

  defp resource_filter(Inventory.Project, %Scope{project_ids: ids}), do: expr(id in ^ids)

  defp resource_filter(Inventory.Person, %Scope{organization_ids: ids}),
    do: expr(organization_id in ^ids)

  defp resource_filter(Inventory.ProjectRole, %Scope{project_ids: ids}),
    do: expr(project_id in ^ids)

  defp resource_filter(Inventory.Application, %Scope{project_ids: ids}),
    do: expr(project_id in ^ids)

  defp resource_filter(Inventory.ProjectRepository, %Scope{
         project_ids: project_ids,
         domain_ids: domain_ids
       }) do
    expr(project_id in ^project_ids or domain_id in ^domain_ids)
  end

  defp resource_filter(Inventory.Datastore, %Scope{project_ids: ids}),
    do: expr(exists([:application], project_id in ^ids))

  defp resource_filter(Inventory.ValueStream, %Scope{brand_ids: ids}),
    do: expr(brand_id in ^ids)

  defp resource_filter(Inventory.BusinessCapability, %Scope{project_ids: ids}),
    do: expr(exists([:application_capabilities, :application], project_id in ^ids))

  defp resource_filter(Inventory.ExternalService, %Scope{project_ids: ids}),
    do: expr(exists([:application_external_services, :application], project_id in ^ids))

  defp resource_filter(Inventory.HostingEnvironment, %Scope{project_ids: ids}),
    do: expr(exists([:applications], project_id in ^ids))

  defp resource_filter(Inventory.NetworkAccess, %Scope{project_ids: ids}),
    do: expr(exists([:applications], project_id in ^ids))

  defp resource_filter(Inventory.ArchitectureConstraint, %Scope{project_ids: ids}),
    do: expr(exists([:application], project_id in ^ids))

  defp resource_filter(Inventory.Registrar, %Scope{domain_ids: ids}),
    do: expr(exists([:domains], id in ^ids))

  defp resource_filter(Inventory.ApplicationValueStream, %Scope{project_ids: ids}),
    do: expr(exists([:application], project_id in ^ids))

  defp resource_filter(Inventory.ApplicationCapability, %Scope{project_ids: ids}),
    do: expr(exists([:application], project_id in ^ids))

  defp resource_filter(Inventory.ApplicationExternalService, %Scope{project_ids: ids}),
    do: expr(exists([:application], project_id in ^ids))

  defp resource_filter(_resource, _scope), do: false
end
