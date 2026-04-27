defmodule Ravner.Domains.DomainTag do
  use Ecto.Schema
  import Ecto.Changeset

  schema "domain_tags" do
    belongs_to(:domain, Ravner.Domains.Domain)
    field(:tag, :string)
    field(:removed_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  def changeset(domain_tag, attrs) do
    domain_tag
    |> cast(attrs, [:domain_id, :tag, :removed_at])
    |> validate_required([:domain_id, :tag])
    |> foreign_key_constraint(:domain_id)
  end
end
