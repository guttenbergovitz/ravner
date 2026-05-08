defmodule Ravner.Repo.Migrations.AddDeepTechFieldsToDomainMetadata do
  use Ecto.Migration

  def change do
    alter table(:domain_metadata) do
      add :tech_evidence, {:array, :map}, default: [], null: false
      add :discovered_urls, {:array, :map}, default: [], null: false
      add :js_assets, {:array, :string}, default: [], null: false
      add :forms, {:array, :map}, default: [], null: false
      add :deep_scan_errors, {:array, :string}, default: [], null: false
      add :deep_tech_scanned_at, :utc_datetime
    end
  end
end
