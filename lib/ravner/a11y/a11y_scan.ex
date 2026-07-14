defmodule Ravner.A11y.A11yScan do
  @moduledoc """
  Ecto schema for accessibility scan results.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ravner.Domains.Domain

  schema "a11y_scans" do
    field :url, :string
    field :standard, :string, default: "WCAG2AA"
    field :status, :string, default: "pending"
    field :violations_count, :integer
    field :warnings_count, :integer
    field :results_raw, :map
    field :error_message, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(scan, attrs) do
    scan
    |> cast(attrs, [
      :domain_id,
      :url,
      :standard,
      :status,
      :violations_count,
      :warnings_count,
      :results_raw,
      :error_message,
      :started_at,
      :completed_at
    ])
    |> validate_required([:domain_id, :url, :standard, :status])
    |> validate_inclusion(:status, ~w(pending running completed failed))
    |> foreign_key_constraint(:domain_id)
  end
end
