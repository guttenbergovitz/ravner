defmodule Ravner.Repo.Migrations.CreateVcsIntegrations do
  use Ecto.Migration

  def change do
    create table(:vcs_integrations) do
      add(:name, :string, null: false)
      add(:provider, :string, null: false, default: "bitbucket")
      add(:workspace, :string, null: false)
      add(:username, :string)
      add(:token, :text)
      add(:active, :boolean, default: true, null: false)
      add(:settings, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:vcs_integrations, [:provider, :workspace]))
    create(index(:vcs_integrations, [:active]))
  end
end
