defmodule Ravner.Repo.Migrations.CreatePeople do
  use Ecto.Migration

  def change do
    create table(:people) do
      add(:first_name, :string, null: false)
      add(:last_name, :string, null: false)
      add(:title, :string)
      add(:email, :string)
      add(:phone, :string)
      add(:mobile, :string)
      add(:default_role, :string)
      add(:notes, :text)
      add(:organization_id, references(:organizations, on_delete: :nilify_all))

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:people, [:email]))
    create(index(:people, [:organization_id]))
    create(index(:people, [:last_name, :first_name]))
  end
end
