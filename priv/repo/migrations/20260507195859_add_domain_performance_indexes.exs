defmodule Ravner.Repo.Migrations.AddDomainPerformanceIndexes do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    create(index(:domains, [:type, :name]))
    create(index(:domains, [:type, :lifecycle_state]))
    create(index(:domains, [:project_id, :type]))
    create(index(:domains, [:organization_id, :type]))
    create(index(:domains, [:brand_id, :type]))
    create(index(:security_scans, [:domain_id, :status, :inserted_at]))

    create(
      index(:domains, ["name gin_trgm_ops"],
        name: :domains_name_trgm_index,
        using: :gin
      )
    )
  end

  def down do
    drop(index(:domains, ["name gin_trgm_ops"], name: :domains_name_trgm_index))
    drop(index(:security_scans, [:domain_id, :status, :inserted_at]))
    drop(index(:domains, [:brand_id, :type]))
    drop(index(:domains, [:organization_id, :type]))
    drop(index(:domains, [:project_id, :type]))
    drop(index(:domains, [:type, :lifecycle_state]))
    drop(index(:domains, [:type, :name]))
  end
end
