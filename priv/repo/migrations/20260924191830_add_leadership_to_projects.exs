defmodule Ravner.Repo.Migrations.AddLeadershipToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :project_manager_id, references(:people, on_delete: :nilify_all)
      add :product_owner_id, references(:people, on_delete: :nilify_all)
    end

    create index(:projects, [:project_manager_id])
    create index(:projects, [:product_owner_id])
  end
end
