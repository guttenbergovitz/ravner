defmodule Ravner.Repo.Migrations.AddRiskScoreToDomainMetadata do
  use Ecto.Migration

  def change do
    alter table(:domain_metadata) do
      add :risk_score, :integer, default: 100
      add :risk_grade, :string, default: "A+"
      add :risk_deductions, :map, default: %{}
      add :risk_drivers, {:array, :string}, default: []
    end

    create index(:domain_metadata, [:risk_score])
    create index(:domain_metadata, [:risk_grade])
  end
end
