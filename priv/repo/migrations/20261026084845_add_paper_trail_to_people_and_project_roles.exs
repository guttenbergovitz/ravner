defmodule Ravner.Repo.Migrations.AddPaperTrailToPeopleAndProjectRoles do
  use Ecto.Migration

  @versioned_tables [
    :people,
    :project_roles
  ]

  def up do
    for table_name <- @versioned_tables do
      version_table = :"#{table_name}_versions"

      create table(version_table, primary_key: false) do
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

      create index(version_table, [:version_source_id])
    end
  end

  def down do
    for table_name <- Enum.reverse(@versioned_tables) do
      version_table = :"#{table_name}_versions"
      drop table(version_table)
    end
  end
end
