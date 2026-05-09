defmodule Ravner.Repo.Migrations.AddGranularScanIntervalsToDomainMetadata do
  use Ecto.Migration

  def change do
    alter table(:domain_metadata) do
      add :http_scan_interval_days, :integer
      add :dns_scan_interval_days, :integer
    end
  end
end
