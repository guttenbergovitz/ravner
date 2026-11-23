defmodule Ravner.Repo.Migrations.CreateProjectRepositorySecrets do
  use Ecto.Migration

  def change do
    create table(:project_repository_secrets) do
      add :project_repository_id, references(:project_repositories, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, on_delete: :nilify_all), null: true
      add :file_path, :string, null: false
      add :line_number, :integer, null: false
      add :rule_id, :string, null: false
      add :rule_name, :string, null: false
      add :masked_value, :string, null: false
      add :fingerprint_sha256, :string, null: false
      add :severity, :string, null: false, default: "critical"
      add :status, :string, null: false, default: "active"
      add :commit_sha, :string

      timestamps(type: :utc_datetime)
    end

    create index(:project_repository_secrets, [:project_repository_id])
    create index(:project_repository_secrets, [:project_id])
    create index(:project_repository_secrets, [:status])

    create unique_index(:project_repository_secrets, [:project_repository_id, :fingerprint_sha256])

    alter table(:project_repositories) do
      add :secrets_count, :integer, default: 0, null: false
    end
  end
end
