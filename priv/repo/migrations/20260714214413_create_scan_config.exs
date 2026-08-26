defmodule Ravner.Repo.Migrations.CreateScanConfig do
  use Ecto.Migration

  def change do
    create table(:scan_config) do
      add :nuclei_severities, {:array, :string},
        null: false,
        default: fragment("ARRAY['critical','high','medium']")

      add :nuclei_tags, {:array, :string}, null: false, default: fragment("ARRAY[]::text[]")

      add :nuclei_exclude_tags, {:array, :string},
        null: false,
        default: fragment("ARRAY[]::text[]")

      timestamps(type: :utc_datetime)
    end

    # Singleton: ensure only one row can exist
    execute "INSERT INTO scan_config (nuclei_severities, nuclei_tags, nuclei_exclude_tags, inserted_at, updated_at) VALUES (ARRAY['critical','high','medium'], ARRAY[]::text[], ARRAY[]::text[], NOW(), NOW())",
            "DELETE FROM scan_config"
  end
end
