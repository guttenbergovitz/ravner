defmodule Ravner.Lighthouse.LighthouseScan do
  @moduledoc """
  Ecto schema for Lighthouse PageSpeed scan results.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ravner.Domains.Domain

  schema "lighthouse_scans" do
    field :url, :string
    field :status, :string, default: "pending"
    field :performance_score, :integer
    field :accessibility_score, :integer
    field :best_practices_score, :integer
    field :seo_score, :integer
    field :fcp_ms, :integer
    field :lcp_ms, :integer
    field :tbt_ms, :integer
    field :cls, :float
    field :speed_index_ms, :integer
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
      :status,
      :performance_score,
      :accessibility_score,
      :best_practices_score,
      :seo_score,
      :fcp_ms,
      :lcp_ms,
      :tbt_ms,
      :cls,
      :speed_index_ms,
      :results_raw,
      :error_message,
      :started_at,
      :completed_at
    ])
    |> validate_required([:domain_id, :url, :status])
    |> validate_inclusion(:status, ~w(pending running completed failed))
    |> foreign_key_constraint(:domain_id)
  end
end
