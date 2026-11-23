defmodule Ravner.Repo.Migrations.AddDomainIdToProjectRepositories do
  use Ecto.Migration

  def change do
    alter table(:project_repositories) do
      modify :project_id, :bigint, null: true, from: :bigint
      add :domain_id, references(:domains, on_delete: :nilify_all), null: true
    end

    create index(:project_repositories, [:domain_id])

    create constraint(:project_repositories, :project_or_domain_required,
             check: "project_id IS NOT NULL OR domain_id IS NOT NULL"
           )
  end
end
