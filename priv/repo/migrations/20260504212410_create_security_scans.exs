defmodule Ravner.Repo.Migrations.CreateSecurityScans do
  use Ecto.Migration

  def change do
    create table(:security_scans) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :tool, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :progress, :integer, default: 0
      add :target, :string
      add :raw_output, :text
      add :summary, :string
      add :error_message, :string

      timestamps()
    end

    create index(:security_scans, [:domain_id])
    create index(:security_scans, [:status])
    create index(:security_scans, [:tool])
  end
end
