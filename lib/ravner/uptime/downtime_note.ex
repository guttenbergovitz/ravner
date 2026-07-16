defmodule Ravner.Uptime.DowntimeNote do
  use Ecto.Schema
  import Ecto.Changeset

  schema "downtime_notes" do
    field :content, :string

    belongs_to :downtime_window, Ravner.Uptime.DowntimeWindow
    belongs_to :author, Ravner.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:content, :downtime_window_id, :author_id])
    |> validate_required([:content, :downtime_window_id])
  end
end
