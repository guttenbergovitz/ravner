defmodule Ravner.Repo.Migrations.AddSchedulingFieldsToDomainMetadata do
  use Ecto.Migration

  def change do
    alter table(:domain_metadata) do
      add :scan_interval_days, :integer
      add :heartbeat_interval_minutes, :integer
      add :ssl_check_interval_days, :integer
      add :tech_discovery_interval_days, :integer
      add :is_up, :boolean
      add :last_heartbeat_at, :utc_datetime
    end
  end
end
