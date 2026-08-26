defmodule Ravner.Repo.Migrations.CreateDomainChecks do
  use Ecto.Migration

  def change do
    create table(:domain_checks) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :url, :string, null: false
      add :label, :string
      add :check_interval_minutes, :integer, null: false, default: 5
      add :failure_threshold, :integer, null: false, default: 2
      add :enabled, :boolean, null: false, default: true
      add :is_up, :boolean
      add :last_checked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:domain_checks, [:domain_id])
    create index(:domain_checks, [:enabled, :last_checked_at])

    # Link heartbeat_checks and downtime_windows to specific checks
    alter table(:heartbeat_checks) do
      add :domain_check_id, references(:domain_checks, on_delete: :delete_all)
    end

    alter table(:downtime_windows) do
      add :domain_check_id, references(:domain_checks, on_delete: :delete_all)
    end

    create index(:heartbeat_checks, [:domain_check_id, :checked_at])
    create index(:downtime_windows, [:domain_check_id])
  end
end
