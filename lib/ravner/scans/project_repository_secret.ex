defmodule Ravner.Scans.ProjectRepositorySecret do
  @moduledoc """
  Schema for secrets and credentials discovered in repository files during VCS scans.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ravner.Inventory.Project
  alias Ravner.Inventory.ProjectRepository

  @statuses ~w(active resolved false_positive)
  @severities ~w(critical high medium low)

  @type t :: %__MODULE__{
          id: integer() | nil,
          project_repository_id: integer(),
          project_repository: ProjectRepository.t() | Ecto.Association.NotLoaded.t(),
          project_id: integer() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          file_path: String.t(),
          line_number: integer(),
          rule_id: String.t(),
          rule_name: String.t(),
          masked_value: String.t(),
          fingerprint_sha256: String.t(),
          severity: String.t(),
          status: String.t(),
          commit_sha: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "project_repository_secrets" do
    field :file_path, :string
    field :line_number, :integer
    field :rule_id, :string
    field :rule_name, :string
    field :masked_value, :string
    field :fingerprint_sha256, :string
    field :severity, :string, default: "critical"
    field :status, :string, default: "active"
    field :commit_sha, :string

    belongs_to :project_repository, ProjectRepository
    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for repository secret records.
  """
  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [
      :project_repository_id,
      :project_id,
      :file_path,
      :line_number,
      :rule_id,
      :rule_name,
      :masked_value,
      :fingerprint_sha256,
      :severity,
      :status,
      :commit_sha
    ])
    |> validate_required([
      :project_repository_id,
      :file_path,
      :line_number,
      :rule_id,
      :rule_name,
      :masked_value,
      :fingerprint_sha256,
      :severity,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:severity, @severities)
    |> unique_constraint([:project_repository_id, :fingerprint_sha256],
      name: :project_repository_secrets_project_repository_id_fingerprint_sh
    )
  end

  def statuses, do: @statuses
  def severities, do: @severities
end
