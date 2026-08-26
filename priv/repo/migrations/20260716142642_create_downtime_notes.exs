defmodule Ravner.Repo.Migrations.CreateDowntimeNotes do
  use Ecto.Migration

  def change do
    create table(:downtime_notes) do
      add :downtime_window_id, references(:downtime_windows, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :nilify_all)
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:downtime_notes, [:downtime_window_id])
  end
end
