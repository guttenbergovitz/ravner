defmodule Ravner.Uptime.SmsAdapters.Log do
  @moduledoc "Dev/test SMS adapter — logs to console."
  @behaviour Ravner.Uptime.SmsAdapter

  require Logger

  @impl true
  def send_sms(to, body, _opts) do
    Logger.info("[SMS:Log] To: #{to} | Body: #{body}")
    {:ok, "log_#{System.unique_integer([:positive])}"}
  end
end
