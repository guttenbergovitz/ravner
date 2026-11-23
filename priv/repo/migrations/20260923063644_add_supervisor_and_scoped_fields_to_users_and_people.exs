defmodule Ravner.Repo.Migrations.AddSupervisorAndScopedFieldsToUsersAndPeople do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :supervisor_id, references(:users, on_delete: :nilify_all)
    end

    create index(:users, [:supervisor_id])

    alter table(:people) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end

    create unique_index(:people, [:user_id])

    alter table(:user_invites) do
      add :target_brand_id, references(:brands, on_delete: :nilify_all)
      add :target_organization_id, references(:organizations, on_delete: :nilify_all)
      add :target_project_id, references(:projects, on_delete: :nilify_all)
      add :supervisor_id, references(:users, on_delete: :nilify_all)
    end

    create index(:user_invites, [:target_brand_id])
    create index(:user_invites, [:target_organization_id])
    create index(:user_invites, [:target_project_id])
    create index(:user_invites, [:supervisor_id])
  end
end
