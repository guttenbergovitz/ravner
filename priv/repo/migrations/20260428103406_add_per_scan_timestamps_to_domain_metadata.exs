defmodule Ravner.Repo.Migrations.AddPerScanTimestampsToDomainMetadata do
  use Ecto.Migration

  def change do
    alter table(:domain_metadata) do
      add(:http_scanned_at, :utc_datetime)
      add(:dns_scanned_at, :utc_datetime)
      add(:subdomains_scanned_at, :utc_datetime)
    end
  end
end
