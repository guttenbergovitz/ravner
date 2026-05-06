defmodule Ravner.Repo.Migrations.AddContactsToDomainMetadata do
  use Ecto.Migration

  def change do
    alter table(:domain_metadata) do
      add :contacts, :map, default: %{}, null: false
    end
  end
end
