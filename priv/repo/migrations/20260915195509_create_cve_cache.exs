defmodule Ravner.Repo.Migrations.CreateCveCache do
  use Ecto.Migration

  def change do
    create table(:cve_cache) do
      add :ecosystem, :string, null: false
      add :package, :string, null: false
      add :version, :string, null: false
      add :findings, :jsonb, default: "[]", null: false
      add :queried_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cve_cache, [:ecosystem, :package, :version])
    create index(:cve_cache, [:expires_at])
  end
end
