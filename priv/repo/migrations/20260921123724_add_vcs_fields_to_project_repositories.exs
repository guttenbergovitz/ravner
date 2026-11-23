defmodule Ravner.Repo.Migrations.AddVcsFieldsToProjectRepositories do
  use Ecto.Migration

  def change do
    alter table(:project_repositories) do
      add(:provider, :string, default: "other", null: false)
      add(:external_id, :string)
      add(:default_branch, :string, default: "main")
      add(:last_commit_hash, :string)
      add(:last_commit_message, :text)
      add(:last_commit_author, :string)
      add(:last_commit_at, :utc_datetime)
    end

    create(index(:project_repositories, [:provider]))
    create(index(:project_repositories, [:external_id]))
  end
end
