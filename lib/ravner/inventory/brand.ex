defmodule Ravner.Inventory.Brand do
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer

  import Ecto.Changeset

  postgres do
    table "brands"
    repo Ravner.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :slug, :display_name, :notes]
    end

    update :update do
      primary? true
      accept [:name, :slug, :display_name, :notes]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :name, :string do
      allow_nil? false
    end

    attribute :slug, :string do
      allow_nil? false
    end

    attribute :display_name, :string
    attribute :notes, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :organizations, Ravner.Inventory.Organization
    # Omit domain cross-context relationship in Ash for now, since Domain is not an Ash Resource yet.
  end

  identities do
    identity :unique_name, [:name]
    identity :unique_slug, [:slug]
  end

  # Keep Ecto changeset for UI compatibility during migration Phase 2-4
  def changeset(brand, attrs) do
    brand
    |> cast(attrs, [:name, :slug, :display_name, :notes])
    |> validate_required([:name, :slug])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end
end
