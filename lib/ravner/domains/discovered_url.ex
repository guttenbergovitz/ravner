defmodule Ravner.Domains.DiscoveredUrl do
  use Ash.Resource,
    domain: Ravner.Domains.AshDomain,
    data_layer: AshPostgres.DataLayer

  import Ecto.Changeset

  postgres do
    table "domain_discovered_urls"
    repo Ravner.Repo
  end

  actions do
    defaults [:read, :destroy, :create, :update]
  end

  attributes do
    integer_primary_key :id
    attribute :url, :string do
      allow_nil? false
    end
    attribute :status, :integer
    attribute :content_type, :string
    attribute :source, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
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
