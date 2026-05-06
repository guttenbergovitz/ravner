defmodule Ravner.SecurityScans.SecurityScan do
  @moduledoc """
  Schema for security scans run against a domain.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ravner.Domains.Domain
  alias Ravner.SecurityScans.ScanFinding

  @type t :: %__MODULE__{
          id: integer() | nil,
          tool: String.t(),
          status: String.t(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          progress: integer(),
          target: String.t() | nil,
          raw_output: String.t() | nil,
          summary: String.t() | nil,
          error_message: String.t() | nil,
          domain_id: integer(),
          domain: Domain.t() | Ecto.Association.NotLoaded.t(),
          findings: [ScanFinding.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "security_scans" do
    field :tool, :string
    field :status, :string, default: "pending"
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :progress, :integer, default: 0
    field :target, :string
    field :raw_output, :string
    field :summary, :string
    field :error_message, :string

    belongs_to :domain, Domain
    has_many :findings, ScanFinding

    timestamps()
  end

  @doc """
  Creates a changeset for a security scan.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(scan, attrs) do
    scan
    |> cast(attrs, [
      :tool,
      :status,
      :started_at,
      :completed_at,
      :progress,
      :target,
      :raw_output,
      :summary,
      :error_message,
      :domain_id
    ])
    |> validate_required([:tool, :status, :domain_id])
    |> validate_inclusion(:tool, [
      "naabu",
      "nuclei",
      "httpx",
      "deep_scan",
      "security_scan"
    ])
    |> validate_inclusion(:status, ["pending", "running", "completed", "failed"])
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> foreign_key_constraint(:domain_id)
  end
end
