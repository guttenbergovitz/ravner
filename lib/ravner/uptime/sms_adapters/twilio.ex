defmodule Ravner.Uptime.SmsAdapters.Twilio do
  @moduledoc """
  SMS delivery via Twilio REST API.
  Credentials from env: TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER.
  """
  @behaviour Ravner.Uptime.SmsAdapter

  require Logger

  @impl true
  def send_sms(to, body, _opts) do
    account_sid = System.get_env("TWILIO_ACCOUNT_SID")
    auth_token = System.get_env("TWILIO_AUTH_TOKEN")
    from = System.get_env("TWILIO_FROM_NUMBER")

    if is_nil(account_sid) || is_nil(auth_token) || is_nil(from) do
      {:error, :missing_twilio_credentials}
    else
      url = "https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Messages.json"

      case Req.post(url,
             form: [{"To", to}, {"From", from}, {"Body", body}],
             auth: {:basic, "#{account_sid}:#{auth_token}"}
           ) do
        {:ok, %{status: 201, body: %{"sid" => sid}}} ->
          {:ok, sid}

        {:ok, %{status: status, body: resp}} ->
          Logger.error("[SMS:Twilio] HTTP #{status}: #{inspect(resp)}")
          {:error, {:http_error, status}}

        {:error, reason} ->
          Logger.error("[SMS:Twilio] Request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end
