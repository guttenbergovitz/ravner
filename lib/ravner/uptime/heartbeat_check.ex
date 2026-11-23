defmodule Ravner.Uptime.HeartbeatCheck do
  @moduledoc """
  Ecto schema recording an individual heartbeat ping result and latency measurement.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{
          id: integer() | nil,
          checked_at: DateTime.t() | nil,
          is_up: boolean() | nil,
          response_time_ms: integer() | nil,
          error_reason: String.t() | nil,
          domain_id: integer() | nil,
          domain: Ravner.Domains.Domain.t() | term(),
          inserted_at: DateTime.t() | nil
        }

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
