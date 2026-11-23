defmodule Ravner.Repo.Migrations.AddIsPrimaryToProjectRepositories do
  use Ecto.Migration

  def change do
    alter table(:project_repositories) do
      add :is_primary, :boolean, default: false, null: false
    end

    create index(:project_repositories, [:domain_id, :is_primary])
  end
end
