defmodule Ravner.Uptime.NotificationPolicy do
  use Ecto.Schema
  import Ecto.Changeset

  schema "uptime_notification_policies" do
    field :name, :string
    field :scope, :string
    field :enabled, :boolean, default: true
    field :still_down_interval_minutes, :integer, default: 30
    field :max_reminders, :integer, default: 5

    belongs_to :domain, Ravner.Domains.Domain
    has_many :recipients, Ravner.Uptime.NotificationRecipient, foreign_key: :policy_id

    many_to_many :groups, Ravner.Uptime.NotificationGroup, join_through: "uptime_policy_groups"

    timestamps(type: :utc_datetime)
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :name,
      :scope,
      :domain_id,
      :enabled,
      :still_down_interval_minutes,
      :max_reminders
    ])
    |> validate_required([:name, :scope])
    |> validate_inclusion(:scope, ["global", "group", "domain"])
  end
end
