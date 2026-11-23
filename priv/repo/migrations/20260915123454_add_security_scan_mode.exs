defmodule Ravner.Repo.Migrations.AddSecurityScanMode do
  use Ecto.Migration

  def change do
    alter table(:scan_config) do
      add :security_scan_mode, :string, null: false, default: "light"
    end
  end
end
