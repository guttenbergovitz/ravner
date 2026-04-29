defmodule Ravner.Repo.Migrations.CreateProjectRoles do
  use Ecto.Migration

  def change do
    create table(:project_roles) do
      add(:project_id, references(:projects, on_delete: :delete_all), null: false)
      add(:person_id, references(:people, on_delete: :delete_all), null: false)
      add(:role, :string, null: false)
      add(:notes, :text)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:project_roles, [:project_id, :person_id]))
    create(index(:project_roles, [:project_id]))
    create(index(:project_roles, [:person_id]))
    create(index(:project_roles, [:role]))
  end
end
