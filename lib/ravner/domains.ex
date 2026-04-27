defmodule Ravner.Domains do
  @moduledoc """
  The Domains context.
  """

  import Ecto.Query, warn: false
  alias Ravner.Repo

  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainTag
  alias Ravner.Domains.DomainMetadata

  # Domains

  def list_domains do
    Repo.all(Domain)
  end

  def list_domains_with_preloads do
    Domain
    |> preload([:parent_domain, :subdomains, :domain_tags, :domain_metadata])
    |> Repo.all()
  end

  def get_domain!(id), do: Repo.get!(Domain, id)

  def get_domain_with_preloads!(id) do
    Domain
    |> preload([:parent_domain, :subdomains, :domain_tags, :domain_metadata])
    |> Repo.get!(id)
  end

  def create_domain(attrs \\ %{}) do
    %Domain{}
    |> Domain.changeset(attrs)
    |> Repo.insert()
  end

  def update_domain(%Domain{} = domain, attrs) do
    domain
    |> Domain.changeset(attrs)
    |> Repo.update()
  end

  def delete_domain(%Domain{} = domain) do
    Repo.delete(domain)
  end

  def change_domain(%Domain{} = domain, attrs \\ %{}) do
    Domain.changeset(domain, attrs)
  end

  def find_domain_by_name(name) do
    Repo.get_by(Domain, name: name)
  end

  # Domain Tags

  def list_domain_tags(domain_id) do
    DomainTag
    |> where([t], t.domain_id == ^domain_id and is_nil(t.removed_at))
    |> Repo.all()
  end

  def add_tag(domain_id, tag) do
    %DomainTag{}
    |> DomainTag.changeset(%{domain_id: domain_id, tag: tag})
    |> Repo.insert()
  end

  def remove_tag(tag_id) do
    Repo.get!(DomainTag, tag_id)
    |> DomainTag.changeset(%{removed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  # Domain Metadata

  def get_domain_metadata(domain_id) do
    Repo.get_by(DomainMetadata, domain_id: domain_id)
  end

  def upsert_domain_metadata(domain_id, attrs) do
    case get_domain_metadata(domain_id) do
      nil ->
        %DomainMetadata{}
        |> DomainMetadata.changeset(Map.put(attrs, :domain_id, domain_id))
        |> Repo.insert()

      metadata ->
        metadata
        |> DomainMetadata.changeset(attrs)
        |> Repo.update()
    end
  end
end
