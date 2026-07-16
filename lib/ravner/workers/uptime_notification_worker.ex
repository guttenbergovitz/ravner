defmodule Ravner.Workers.UptimeNotificationWorker do
  @moduledoc """
  Oban worker that delivers uptime notifications for a downtime event.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ravner.Repo
  alias Ravner.Uptime.Notifications
  alias Ravner.Uptime.DowntimeWindow
  alias Ravner.Domains

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"event" => event, "downtime_window_id" => window_id, "domain_id" => domain_id}
      }) do
    window = Repo.get!(DowntimeWindow, window_id)
    domain = Domains.get_domain!(domain_id)
    recipients = Notifications.resolve_recipients(domain_id)

    for recipient <- recipients do
      Notifications.deliver_to_recipient(recipient, event, window, domain_name: domain.name)
    end

    :ok
  end
end
