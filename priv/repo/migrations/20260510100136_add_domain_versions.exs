defmodule Ravner.Repo.Migrations.AddDomainVersions do
  use Ecto.Migration

  def up do
    create table(:domains_versions, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true
      add :version_action_type, :text, null: false
      add :version_action_name, :text, null: false
      add :version_source_id, :bigint, null: false
      add :changes, :map

      add :version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end
  end

  def down do
    drop table(:domains_versions)
  end
end
