defmodule Ravner.Domains.TechEvidence do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "domain_tech_evidence" do
    belongs_to(:domain, Ravner.Domains.Domain)
    field(:name, :string)
    field(:version, :string)
    field(:source, :string)
    field(:confidence, :integer)

    timestamps(type: :utc_datetime)
  end

  def changeset(tech_evidence, attrs) do
    tech_evidence
    |> cast(attrs, [:domain_id, :name, :version, :source, :confidence])
    |> validate_required([:domain_id, :name])
  end
end
