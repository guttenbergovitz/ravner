defmodule Ravner.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:description, :text)
      add(:notes, :text)
      add(:organization_id, references(:organizations, on_delete: :nilify_all), null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:projects, [:name]))
    create(unique_index(:projects, [:slug]))
    create(index(:projects, [:organization_id]))
  end
end
