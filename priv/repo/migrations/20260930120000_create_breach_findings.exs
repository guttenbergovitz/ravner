defmodule Ravner.Repo.Migrations.CreateBreachFindings do
  use Ecto.Migration

  def change do
    create table(:breach_findings) do
      add :domain, :string, null: false
      add :title, :string, null: false
      add :severity, :string, null: false
      add :detail, :map, default: %{}, null: false
      add :status, :string, null: false, default: "new"
      add :external_id, :string
      add :source, :string

      timestamps()
    end

    create unique_index(:breach_findings, [:domain, :title, :source],
             name: :unique_finding_per_domain_source
           )
  end
end
