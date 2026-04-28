defmodule Ravner.Repo.Migrations.CreateUserInvites do
  use Ecto.Migration

  def change do
    create table(:user_invites) do
      add(:token, :string, null: false)
      add(:email, :string, null: false)
      add(:role, :string, null: false, default: "viewer")
      add(:name, :string)
      add(:invited_by_id, references(:users, on_delete: :nilify_all))
      add(:accepted_at, :utc_datetime)
      add(:expires_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:user_invites, [:token]))
    create(index(:user_invites, [:email]))
  end
end
