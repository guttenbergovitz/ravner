defmodule Ravner.Repo.Migrations.CreateDomainTags do
  use Ecto.Migration

  def change do
    create table(:domain_tags) do
      add(:domain_id, references(:domains, on_delete: :delete_all), null: false)
      add(:tag, :string, null: false)
      add(:removed_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:domain_tags, [:domain_id]))
    create(index(:domain_tags, [:tag]))
    create(unique_index(:domain_tags, [:domain_id, :tag], where: "removed_at IS NULL"))
  end
end
