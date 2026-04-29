defmodule Ravner.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations) do
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:type, :string, null: false, default: "internal")
      add(:country, :string)
      add(:notes, :text)
      add(:brand_id, references(:brands, on_delete: :nilify_all))

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:organizations, [:name]))
    create(unique_index(:organizations, [:slug]))
    create(index(:organizations, [:brand_id]))
    create(index(:organizations, [:type]))
  end
end
