defmodule Ravner.Repo.Migrations.AddLeanScannerFieldsToDomainMetadata do
  use Ecto.Migration

  def change do
    alter table(:domain_metadata) do
      add :open_ports, {:array, :integer}, default: []
      add :last_security_scan_at, :utc_datetime
    end
  end
end
