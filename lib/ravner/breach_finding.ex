defmodule Ravner.BreachFinding do
  @moduledoc """
  Modeluje pojedyncze znalezienie z dark‑webu (infostealer reports).
  Statusy: "new", "resolved", "false_positive", "ignored".
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer(),
          domain: String.t(),
          title: String.t(),
          severity: String.t(),
          detail: map(),
          status: String.t(),
          source: String.t(),
          external_id: String.t() | nil,
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  schema "breach_findings" do
    field :domain, :string
    field :title, :string
    field :severity, :string
    field :detail, :map, default: %{}
    field :status, :string, default: "new"
    field :source, :string
    field :external_id, :string

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(finding, attrs) do
    finding
    |> cast(attrs, [:domain, :title, :severity, :detail, :status, :source, :external_id])
    |> validate_required([:domain, :title, :severity, :detail, :source])
    |> unique_constraint([:domain, :title, :source], name: :unique_finding_per_domain_source)
  end
end
