defmodule Ravner.Repo.Migrations.CreateHeartbeatChecks do
  use Ecto.Migration

  def change do
    create table(:heartbeat_checks) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :checked_at, :utc_datetime, null: false
      add :is_up, :boolean, null: false
      add :response_time_ms, :integer
      add :error_reason, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:heartbeat_checks, [:domain_id, :checked_at])
    create index(:heartbeat_checks, [:checked_at])
  end
end
