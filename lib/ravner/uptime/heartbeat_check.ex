defmodule Ravner.Uptime.HeartbeatCheck do
  use Ecto.Schema

  schema "heartbeat_checks" do
    field :checked_at, :utc_datetime
    field :is_up, :boolean
    field :response_time_ms, :integer
    field :error_reason, :string

    belongs_to :domain, Ravner.Domains.Domain
    belongs_to :domain_check, Ravner.Uptime.DomainCheck

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
