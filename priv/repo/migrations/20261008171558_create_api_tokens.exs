defmodule Ravner.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens) do
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :prefix, :string, null: false
      add :role, :string, null: false, default: "viewer"
      add :allowed_ips, {:array, :string}, default: []
      add :allowed_paths, {:array, :string}, default: []
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :last_used_at, :utc_datetime
      add :last_used_ip, :string
      add :created_by_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:prefix])
    create index(:api_tokens, [:revoked_at])
    create index(:api_tokens, [:expires_at])

    create table(:api_tokens_versions, primary_key: false) do
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

    create index(:api_tokens_versions, [:version_source_id])
  end
end
