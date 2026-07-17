defmodule Ravner.Repo.Migrations.CreateDeliverySettings do
  use Ecto.Migration

  def change do
    create table(:delivery_settings) do
      add :key, :string, null: false
      add :value_encrypted, :binary
      add :value_plain, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:delivery_settings, [:key])
  end
end
