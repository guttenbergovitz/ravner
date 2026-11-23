defmodule Ravner.Uptime.NotificationRecipient do
  use Ecto.Schema
  import Ecto.Changeset

  schema "uptime_notification_recipients" do
    field :email, :string
    field :phone, :string
    field :channels, :string, default: "email"
    field :webhook_url, :string
    field :webhook_type, :string, default: "generic"
    field :secret_header, :string

    belongs_to :policy, Ravner.Uptime.NotificationPolicy
    belongs_to :group, Ravner.Uptime.NotificationGroup
    belongs_to :user, Ravner.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @allowed_channels ["email", "sms", "both", "webhook", "all"]
  @allowed_webhook_types ["slack", "teams", "discord", "generic"]

  def changeset(recipient, attrs) do
    recipient
    |> cast(attrs, [
      :email,
      :phone,
      :channels,
      :webhook_url,
      :webhook_type,
      :secret_header,
      :policy_id,
      :group_id,
      :user_id
    ])
    |> validate_required([:channels])
    |> validate_inclusion(:channels, @allowed_channels)
    |> validate_inclusion(:webhook_type, @allowed_webhook_types)
    |> validate_has_contact()
    |> validate_webhook()
  end

  defp validate_has_contact(changeset) do
    user_id = get_field(changeset, :user_id)
    email = get_field(changeset, :email)
    phone = get_field(changeset, :phone)
    webhook_url = get_field(changeset, :webhook_url)

    if is_nil(user_id) && is_nil(email) && is_nil(phone) && is_nil(webhook_url) do
      add_error(changeset, :email, "must provide a user, email, phone, or webhook URL")
    else
      changeset
    end
  end

  defp validate_webhook(changeset) do
    channels = get_field(changeset, :channels)
    webhook_url = get_field(changeset, :webhook_url)

    cond do
      channels in ["webhook", "all"] and (is_nil(webhook_url) or webhook_url == "") ->
        add_error(
          changeset,
          :webhook_url,
          "must provide a webhook URL when webhook channel is selected"
        )

      is_binary(webhook_url) and webhook_url != "" ->
        case Ravner.Notifications.WebhookDispatcher.validate_url(webhook_url) do
          {:ok, _} -> changeset
          {:error, reason} -> add_error(changeset, :webhook_url, reason)
        end

      true ->
        changeset
    end
  end
end
