defmodule Ravner.Uptime.DowntimeNote do
  @moduledoc """
  Ecto schema representing a governance or root-cause annotation attached to a downtime incident.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          content: String.t() | nil,
          downtime_window_id: integer() | nil,
          downtime_window: Ravner.Uptime.DowntimeWindow.t() | term(),
          author_id: integer() | nil,
          author: Ravner.Accounts.User.t() | term(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

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
