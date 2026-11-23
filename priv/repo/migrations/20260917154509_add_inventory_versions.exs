defmodule Ravner.Repo.Migrations.AddInventoryVersions do
  use Ecto.Migration

  def up do
    create table(:brands_versions, primary_key: false) do
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

    create index(:brands_versions, [:version_source_id])

    create table(:organizations_versions, primary_key: false) do
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

    create index(:organizations_versions, [:version_source_id])

    create table(:projects_versions, primary_key: false) do
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

    create index(:projects_versions, [:version_source_id])
  end

  def down do
    drop table(:projects_versions)
    drop table(:organizations_versions)
    drop table(:brands_versions)
  end
end
