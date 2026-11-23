defmodule Ravner.Domains.DnsRecord do
  @moduledoc """
  Ecto schema representing a DNS record for a domain.
  """
  use Ash.Resource,
    domain: Ravner.Domains.AshDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("domain_dns_records")
    repo(Ravner.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if({Ravner.Accounts.ScopeReadCheck, []})
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(actor_attribute_equals(:role, :editor))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:domain_id, :type, :value, :ttl])
    end

    update :update do
      primary?(true)
      accept([:domain_id, :type, :value, :ttl])
    end
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
    belongs_to :domain, Ravner.Domains.Domain, attribute_type: :integer, public?: true
  end

  def changeset(dns_record, attrs) do
    dns_record
    |> cast(attrs, [:domain_id, :type, :value, :ttl])
    |> validate_required([:domain_id, :type, :value])
  end
end
