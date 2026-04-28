defmodule Ravner.Repo.Migrations.AddRoleAndNameToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:role, :string, null: false, default: "viewer")
      add(:name, :string)
      add(:active, :boolean, null: false, default: true)
    end
  end
end
