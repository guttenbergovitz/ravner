defmodule Ravner.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys) do
      add(:name, :string, null: false)
      add(:key_encrypted, :text, null: false)
      add(:key_type, :string, null: false, default: "settings")
      add(:last_validated_at, :utc_datetime)
      add(:is_valid, :boolean, default: nil)
      add(:error_message, :string)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:api_keys, [:name]))
  end
end
