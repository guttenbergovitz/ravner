defmodule Ravner.Repo.Migrations.AddDomainTechnicalStatus do
  use Ecto.Migration

  def up do
    alter table(:domains) do
      add(:technical_status, :string, null: false, default: "unknown")
    end

    execute("""
    UPDATE domains
    SET technical_status = CASE lifecycle_state
      WHEN 'redirect' THEN 'redirect'
      WHEN 'insecure' THEN 'insecure'
      WHEN 'error' THEN 'error'
      WHEN 'active' THEN 'reachable'
      ELSE technical_status
    END
    """)

    execute("""
    UPDATE domains
    SET lifecycle_state = 'under_review'
    WHERE lifecycle_state IN ('redirect', 'insecure', 'error')
    """)

    create(index(:domains, [:technical_status]))
  end

  def down do
    drop(index(:domains, [:technical_status]))

    alter table(:domains) do
      remove(:technical_status)
    end
  end
end
