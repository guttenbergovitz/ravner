defmodule Ravner.Uptime.NotificationDelivery do
  use Ecto.Schema

  schema "uptime_notification_deliveries" do
    field :event_type, :string
    field :sequence, :integer, default: 0
    field :channel, :string
    field :delivered_at, :utc_datetime
    field :error, :string

    belongs_to :downtime_window, Ravner.Uptime.DowntimeWindow
    belongs_to :recipient, Ravner.Uptime.NotificationRecipient

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
