defmodule Ravner.Domains.DnsRecord do
  @moduledoc """
  Ecto schema representing a DNS record for a domain.
  """
  use Ash.Resource,
    domain: Ravner.Domains.AshDomain,
    data_layer: AshPostgres.DataLayer

  import Ecto.Changeset

  postgres do
    table("domain_dns_records")
    repo(Ravner.Repo)
  end

  actions do
    defaults([:read, :destroy, :create, :update])
  end

  attributes do
    integer_primary_key(:id)

    attribute :type, :string do
      allow_nil?(false)
    end

    attribute :value, :string do
      allow_nil?(false)
    end

    attribute(:ttl, :integer)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :domain, Ravner.Domains.Domain, attribute_type: :integer
  end

  def changeset(dns_record, attrs) do
    dns_record
    |> cast(attrs, [:domain_id, :type, :value, :ttl])
    |> validate_required([:domain_id, :type, :value])
  end
end
