defmodule Ravner.Repo.Migrations.CreateA11yScans do
  use Ecto.Migration

  def change do
    create table(:a11y_scans) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :url, :string, null: false
      add :standard, :string, null: false, default: "WCAG2AA"
      add :status, :string, null: false, default: "pending"
      add :violations_count, :integer
      add :warnings_count, :integer
      add :results_raw, :map
      add :error_message, :text
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:a11y_scans, [:domain_id])
    create index(:a11y_scans, [:domain_id, :status])

    alter table(:domain_metadata) do
      add :a11y_scan_interval_days, :integer
      add :last_a11y_scan_at, :utc_datetime
    end
  end
end
