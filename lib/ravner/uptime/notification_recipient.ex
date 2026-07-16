defmodule Ravner.Uptime.NotificationRecipient do
  use Ecto.Schema
  import Ecto.Changeset

  schema "uptime_notification_recipients" do
    field :email, :string
    field :phone, :string
    field :channels, :string, default: "email"

    belongs_to :policy, Ravner.Uptime.NotificationPolicy
    belongs_to :group, Ravner.Uptime.NotificationGroup
    belongs_to :user, Ravner.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(recipient, attrs) do
    recipient
    |> cast(attrs, [:email, :phone, :channels, :policy_id, :group_id, :user_id])
    |> validate_required([:channels])
    |> validate_inclusion(:channels, ["email", "sms", "both"])
    |> validate_has_contact()
  end

  defp validate_has_contact(changeset) do
    user_id = get_field(changeset, :user_id)
    email = get_field(changeset, :email)
    phone = get_field(changeset, :phone)

    if is_nil(user_id) && is_nil(email) && is_nil(phone) do
      add_error(changeset, :email, "must provide a user, email, or phone")
    else
      changeset
    end
  end
end
