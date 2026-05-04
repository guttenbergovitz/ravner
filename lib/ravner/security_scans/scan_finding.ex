defmodule Ravner.SecurityScans.ScanFinding do
  @moduledoc """
  Schema for individual findings discovered during a security scan.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ravner.SecurityScans.SecurityScan

  @type t :: %__MODULE__{
          id: integer() | nil,
          severity: String.t() | nil,
          title: String.t(),
          target: String.t() | nil,
          detail: map() | nil,
          security_scan_id: integer(),
          security_scan: SecurityScan.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "scan_findings" do
    field :severity, :string
    field :title, :string
    field :target, :string
    field :detail, :map

    belongs_to :security_scan, SecurityScan

    timestamps()
  end

  @doc """
  Creates a changeset for a scan finding.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(finding, attrs) do
    finding
    |> cast(attrs, [:severity, :title, :target, :detail, :security_scan_id])
    |> validate_required([:title, :security_scan_id])
    |> validate_inclusion(:severity, ["critical", "high", "medium", "low", "info", nil])
    |> foreign_key_constraint(:security_scan_id)
  end
end
