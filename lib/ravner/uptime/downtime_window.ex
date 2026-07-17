defmodule Ravner.Uptime.DowntimeWindow do
  use Ecto.Schema

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
