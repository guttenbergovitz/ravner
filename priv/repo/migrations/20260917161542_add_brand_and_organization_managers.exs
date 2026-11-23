defmodule Ravner.Repo.Migrations.AddBrandAndOrganizationManagers do
  use Ecto.Migration

  def change do
    alter table(:brands) do
      add :brand_manager_id, references(:people, on_delete: :nilify_all)
    end

    create index(:brands, [:brand_manager_id])

    alter table(:organizations) do
      add :manager_id, references(:people, on_delete: :nilify_all)
    end

    create index(:organizations, [:manager_id])
  end
end
