defmodule Ravner.Repo.Migrations.AddSecurityScannerToScanConfig do
  use Ecto.Migration

  def change do
    alter table(:scan_config) do
      add :security_scanner, :string, null: false, default: "nuclei"
    end
  end
end
