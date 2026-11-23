defmodule Ravner.Repo.Migrations.UpdateRiskScoreDefaultsOnDomainMetadata do
  use Ecto.Migration

  def change do
    alter table(:domain_metadata) do
      modify :risk_score, :integer,
        default: nil,
        null: true,
        from: {:integer, [default: 100, null: true]}

      modify :risk_grade, :string,
        default: "N/A",
        null: true,
        from: {:string, [default: "A+", null: true]}
    end
  end
end
