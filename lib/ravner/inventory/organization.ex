defmodule Ravner.Inventory.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  schema "organizations" do
    field(:name, :string)
    field(:slug, :string)
    field(:display_name, :string)

    field(:type, Ecto.Enum,
      values: [:internal, :client, :contractor, :partner],
      default: :internal
    )

    field(:country, :string)
    field(:notes, :string)

    belongs_to(:brand, Ravner.Inventory.Brand)
    has_many(:projects, Ravner.Inventory.Project)
    has_many(:people, Ravner.Inventory.Person)
    has_many(:domains, Ravner.Domains.Domain)

    timestamps(type: :utc_datetime)
  end

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
