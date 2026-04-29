defmodule Ravner.Repo.Migrations.CreateBrands do
  use Ecto.Migration

  def change do
    create table(:brands) do
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:notes, :text)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:brands, [:name]))
    create(unique_index(:brands, [:slug]))
  end
end
