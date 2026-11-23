defmodule Ravner.Uptime.DowntimeWindow do
  @moduledoc """
  Ecto schema tracking a discrete downtime incident window from initial failure to recovery.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{
          id: integer() | nil,
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          duration_seconds: integer() | nil,
          failure_threshold_used: integer(),
          domain_id: integer() | nil,
          domain: Ravner.Domains.Domain.t() | term(),
          notes: [Ravner.Uptime.DowntimeNote.t()] | term(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "downtime_windows" do
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :duration_seconds, :integer
    field :failure_threshold_used, :integer, default: 2

    belongs_to :domain, Ravner.Domains.Domain
    belongs_to :domain_check, Ravner.Uptime.DomainCheck

    has_many :notes, Ravner.Uptime.DowntimeNote

    timestamps(type: :utc_datetime)
  end
end
