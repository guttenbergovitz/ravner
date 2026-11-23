defmodule Ravner.Repo.Migrations.AddSslScannedAtToDomainMetadata do
  use Ecto.Migration

  def change do
    alter table(:domain_metadata) do
      add :ssl_scanned_at, :utc_datetime
    end

    create index(:domain_metadata, [:ssl_check_interval_days, :ssl_scanned_at])
  end
end
