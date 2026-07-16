defmodule Ravner.Uptime.NotificationGroup do
  use Ecto.Schema
  import Ecto.Changeset

  schema "uptime_notification_groups" do
    field :name, :string
    field :description, :string

    has_many :recipients, Ravner.Uptime.NotificationRecipient, foreign_key: :group_id

    many_to_many :policies, Ravner.Uptime.NotificationPolicy, join_through: "uptime_policy_groups"

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
