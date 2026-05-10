defmodule Ravner.Inventory.Organization do
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer

  import Ecto.Changeset

  postgres do
    table "organizations"
    repo Ravner.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :slug, :display_name, :type, :country, :notes, :brand_id]
    end

    update :update do
      primary? true
      accept [:name, :slug, :display_name, :type, :country, :notes, :brand_id]
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
    
    attribute :type, :atom do
      constraints [one_of: [:internal, :client, :contractor, :partner]]
      default :internal
      allow_nil? false
    end

    attribute :country, :string
    attribute :notes, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :brand, Ravner.Inventory.Brand, attribute_type: :integer
    has_many :projects, Ravner.Inventory.Project
    has_many :people, Ravner.Inventory.Person
    # Omit domain cross-context relationship in Ash for now
  end

  identities do
    identity :unique_name, [:name]
    identity :unique_slug, [:slug]
  end

  # Keep Ecto changeset for UI compatibility during migration Phase 2-4
  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :slug, :display_name, :type, :country, :notes, :brand_id])
    |> validate_required([:name, :slug, :type])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> generate_slug()
  end

  defp generate_slug(changeset) do
    slug = get_field(changeset, :slug)

    if slug && slug != "" do
      changeset
    else
      name = get_field(changeset, :name)

      if name do
        auto =
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        put_change(changeset, :slug, auto)
      else
        changeset
      end
    end
  end
end
