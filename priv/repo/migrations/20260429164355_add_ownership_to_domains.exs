defmodule Ravner.Repo.Migrations.AddOwnershipToDomains do
  use Ecto.Migration

  def change do
    alter table(:domains) do
      add(:project_id, references(:projects, on_delete: :nilify_all))
      add(:brand_id, references(:brands, on_delete: :nilify_all))
      add(:organization_id, references(:organizations, on_delete: :nilify_all))
    end

    create(index(:domains, [:project_id]))
    create(index(:domains, [:brand_id]))
    create(index(:domains, [:organization_id]))
  end
end
