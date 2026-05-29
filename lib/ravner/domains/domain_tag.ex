defmodule Ravner.Domains.DomainTag do
  @moduledoc """
  Ecto schema representing a tag associated with a domain.
  """
  use Ash.Resource,
    domain: Ravner.Domains.AshDomain,
    data_layer: AshPostgres.DataLayer

  import Ecto.Changeset

  postgres do
    table("domain_tags")
    repo(Ravner.Repo)
  end

  actions do
    defaults([:read, :destroy, :create, :update])
  end

  attributes do
    integer_primary_key(:id)

    attribute :tag, :string do
      allow_nil?(false)
    end

    attribute(:removed_at, :utc_datetime)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :domain, Ravner.Domains.Domain, attribute_type: :integer
  end

  # Keep Ecto changeset for compatibility
  def changeset(domain_tag, attrs) do
    domain_tag
    |> cast(attrs, [:domain_id, :tag, :removed_at])
    |> validate_required([:domain_id, :tag])
    |> foreign_key_constraint(:domain_id)
  end
end
