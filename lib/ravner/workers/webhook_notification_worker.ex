defmodule Ravner.Workers.WebhookNotificationWorker do
  @moduledoc """
  Asynchronous Oban worker for dispatching webhook notifications to external services.
  Runs on the dedicated `:notifications` Oban queue with automatic retry backoff.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  require Logger

  alias Ravner.Repo
  alias Ravner.Uptime.NotificationRecipient
  alias Ravner.Notifications.WebhookDispatcher

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "recipient_id" => recipient_id,
            "event_type" => event_type,
            "payload" => payload
          } = args
      }) do
    case Repo.get(NotificationRecipient, recipient_id) do
      nil ->
        Logger.warning(
          "Notification recipient #{recipient_id} not found, skipping webhook delivery"
        )

        :ok

      %NotificationRecipient{} = recipient ->
        opts = build_opts(args)

        case WebhookDispatcher.deliver_event(recipient, event_type, payload, opts) do
          {:ok, _resp} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def perform(%Oban.Job{
        args:
          %{
            "webhook_url" => url,
            "event_type" => event_type,
            "payload" => payload
          } = args
      }) do
    type = Map.get(args, "webhook_type", "generic")
    secret = Map.get(args, "secret_header")
    opts = build_opts(args) |> Keyword.put(:secret, secret)

    case WebhookDispatcher.dispatch(url, type, event_type, payload, opts) do
      {:ok, _resp} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_opts(args) do
    opts = []

    opts =
      if Map.get(args, "allow_private_ips", true) do
        Keyword.put(opts, :allow_private_ips, true)
      else
        opts
      end

    case Application.get_env(:ravner, :webhook_req_options) do
      nil -> opts
      req_opts -> Keyword.put(opts, :req_options, req_opts)
    end
  end
end
