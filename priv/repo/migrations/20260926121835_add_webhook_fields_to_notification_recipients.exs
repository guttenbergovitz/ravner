defmodule Ravner.Repo.Migrations.AddWebhookFieldsToNotificationRecipients do
  use Ecto.Migration

  def change do
    alter table(:uptime_notification_recipients) do
      add :webhook_url, :string
      add :webhook_type, :string, default: "generic"
      add :secret_header, :string
    end
  end
end
