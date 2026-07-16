defmodule Ravner.Repo.Migrations.CreateDowntimeWindows do
  use Ecto.Migration

  def change do
    create table(:downtime_windows) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      add :duration_seconds, :integer
      add :failure_threshold_used, :integer, null: false, default: 2

      timestamps(type: :utc_datetime)
    end

    create index(:downtime_windows, [:domain_id, :started_at])

    create index(:downtime_windows, [:domain_id],
      where: "ended_at IS NULL",
      name: :downtime_windows_open_idx
    )
  end
end
