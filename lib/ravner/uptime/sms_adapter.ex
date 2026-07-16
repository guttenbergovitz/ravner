defmodule Ravner.Uptime.SmsAdapter do
  @moduledoc """
  Behaviour for SMS delivery adapters.
  """

  @callback send_sms(to :: String.t(), body :: String.t(), opts :: keyword()) ::
              {:ok, reference_id :: String.t()} | {:error, reason :: term()}

  @doc """
  Returns the currently configured adapter module.
  """
  def adapter do
    Application.get_env(:ravner, :uptime_sms_adapter, Ravner.Uptime.SmsAdapters.Log)
  end

  @doc """
  Sends an SMS using the configured adapter.
  """
  def send_sms(to, body, opts \\ []) do
    adapter().send_sms(to, body, opts)
  end
end
