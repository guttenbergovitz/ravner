defmodule Ravner.Repo.Migrations.CreateScanFindings do
  use Ecto.Migration

  def change do
    create table(:scan_findings) do
      add :security_scan_id, references(:security_scans, on_delete: :delete_all), null: false
      add :severity, :string
      add :title, :string, null: false
      add :target, :string
      add :detail, :map

      timestamps()
    end

    create index(:scan_findings, [:security_scan_id])
    create index(:scan_findings, [:severity])
  end
end
