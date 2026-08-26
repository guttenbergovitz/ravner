defmodule RavnerWeb.UserSessionHTML do
  use RavnerWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:ravner, Ravner.Mailer)[:adapter] == Swoosh.Adapters.Local
  end

  defp mailer_configured? do
    alias Ravner.DeliverySettings

    provider = DeliverySettings.current_email_provider()

    case provider do
      "sendgrid" ->
        DeliverySettings.get("email_sendgrid_api_key") != nil

      "mailgun" ->
        DeliverySettings.get("email_mailgun_api_key") != nil &&
          DeliverySettings.get("email_mailgun_domain") != nil

      "postmark" ->
        DeliverySettings.get("email_postmark_api_key") != nil

      "smtp" ->
        DeliverySettings.get("email_smtp_host") != nil &&
          DeliverySettings.get("email_smtp_username") != nil

      _ ->
        false
    end
  end
end
