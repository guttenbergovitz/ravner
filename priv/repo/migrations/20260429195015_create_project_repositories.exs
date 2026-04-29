defmodule Ravner.Repo.Migrations.CreateProjectRepositories do
  use Ecto.Migration

  def change do
    create table(:project_repositories) do
      add(:project_id, references(:projects, on_delete: :delete_all), null: false)
      add(:url, :string, null: false)
      add(:kind, :string, null: false, default: "website")
      add(:main_language, :string)
      add(:technology, :string)
      add(:notes, :text)

      timestamps(type: :utc_datetime)
    end

    create(index(:project_repositories, [:project_id]))
    create(index(:project_repositories, [:kind]))
  end
end
