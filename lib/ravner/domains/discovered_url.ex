defmodule Ravner.Domains.DiscoveredUrl do
  @moduledoc """
  Ecto schema representing a URL discovered during crawling.
  """
  use Ash.Resource,
    domain: Ravner.Domains.AshDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("domain_discovered_urls")
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
    defaults([:read, :destroy, :create, :update])
  end

  attributes do
    integer_primary_key(:id)

    attribute :url, :string do
      allow_nil?(false)
    end

    attribute(:status, :integer)
    attribute(:content_type, :string)
    attribute(:source, :string)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :domain, Ravner.Domains.Domain, attribute_type: :integer
  end

  def changeset(discovered_url, attrs) do
    discovered_url
    |> cast(attrs, [:domain_id, :url, :status, :content_type, :source])
    |> validate_required([:domain_id, :url])
  end
end
