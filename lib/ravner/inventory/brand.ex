defmodule Ravner.Inventory.Brand do
  use Ecto.Schema
  import Ecto.Changeset

  schema "brands" do
    field(:name, :string)
    field(:slug, :string)
    field(:notes, :string)

    has_many(:organizations, Ravner.Inventory.Organization)
    has_many(:domains, Ravner.Domains.Domain)

    timestamps(type: :utc_datetime)
  end

  def changeset(brand, attrs) do
    brand
    |> cast(attrs, [:name, :slug, :notes])
    |> validate_required([:name, :slug])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end
end
