defmodule RavnerWeb.UserSessionHTML do
  use RavnerWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:ravner, Ravner.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
