defmodule Ravner.Repo.Migrations.AddDisplayNameToOwnership do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add(:display_name, :string)
    end

    alter table(:projects) do
      add(:display_name, :string)
    end

    alter table(:brands) do
      add(:display_name, :string)
    end
  end
end
