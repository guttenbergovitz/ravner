defmodule Ravner.Repo.Migrations.AddAccountsAuditVersions do
  use Ecto.Migration

  def up do
    create_version_table(:users_versions)
    create_version_table(:users_tokens_versions)
    create_version_table(:user_invites_versions)
  end

  def down do
    drop table(:user_invites_versions)
    drop table(:users_tokens_versions)
    drop table(:users_versions)
  end

  defp create_version_table(table) do
    create table(table, primary_key: false) do
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

    create index(table, [:version_source_id])
  end
end
