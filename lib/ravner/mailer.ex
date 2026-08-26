defmodule Ravner.Mailer do
  use Swoosh.Mailer, otp_app: :ravner

  alias Ravner.DeliverySettings

  def deliver(email, config \\ []) do
    adapter_config = build_adapter_config()
    config = Keyword.merge(adapter_config, config)
    super(email, config)
  end

  defp build_adapter_config do
    case DeliverySettings.current_email_provider() do
      "sendgrid" ->
        [
          adapter: Swoosh.Adapters.Sendgrid,
          api_key: DeliverySettings.get("email_sendgrid_api_key")
        ]

      "mailgun" ->
        [
          adapter: Swoosh.Adapters.Mailgun,
          api_key: DeliverySettings.get("email_mailgun_api_key"),
          domain: DeliverySettings.get("email_mailgun_domain")
        ]

      "postmark" ->
        [
          adapter: Swoosh.Adapters.Postmark,
          api_key: DeliverySettings.get("email_postmark_api_key")
        ]

      _ ->
        # Default to SMTP
        [
          adapter: Swoosh.Adapters.SMTP,
          relay: DeliverySettings.get("email_smtp_host") || System.get_env("SMTP_HOST"),
          port:
            (DeliverySettings.get("email_smtp_port") || System.get_env("SMTP_PORT") || "587")
            |> String.to_integer(),
          username:
            DeliverySettings.get("email_smtp_username") || System.get_env("SMTP_USERNAME"),
          password:
            DeliverySettings.get("email_smtp_password") || System.get_env("SMTP_PASSWORD"),
          tls: :if_available,
          auth: :if_available
        ]
    end
  end
end
