defmodule Ravner.Repo.Migrations.CreateLighthouseScans do
  use Ecto.Migration

  def change do
    create table(:lighthouse_scans) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :url, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :performance_score, :integer
      add :accessibility_score, :integer
      add :best_practices_score, :integer
      add :seo_score, :integer
      add :fcp_ms, :integer
      add :lcp_ms, :integer
      add :tbt_ms, :integer
      add :cls, :float
      add :speed_index_ms, :integer
      add :results_raw, :map
      add :error_message, :text
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:lighthouse_scans, [:domain_id])
    create index(:lighthouse_scans, [:domain_id, :status])

    alter table(:domain_metadata) do
      add :lighthouse_scan_interval_days, :integer
      add :last_lighthouse_scan_at, :utc_datetime
    end
  end
end
