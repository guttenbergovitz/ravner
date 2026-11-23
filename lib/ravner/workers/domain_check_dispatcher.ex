defmodule Ravner.Workers.DomainCheckDispatcher do
  @moduledoc """
  Dispatches HeartbeatWorker jobs for domain_checks that are due.
  Runs every minute via Oban cron (same as HeartbeatDispatcher).
  """
  use Oban.Worker,
    queue: :default,
    unique: [period: 120, fields: [:args]]

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Uptime.DomainCheck

  @impl Oban.Worker
  def perform(_job) do
    query =
      from(c in DomainCheck,
        where: c.enabled == true,
        where:
          is_nil(c.last_checked_at) or
            fragment(
              "? + ? * interval '1 minute' < ?",
              c.last_checked_at,
              c.check_interval_minutes,
              from_now(0, "second")
            ),
        select: {c.id, c.domain_id}
      )

    query
    |> Repo.all()
    |> Enum.map(fn {check_id, domain_id} ->
      %{domain_id: domain_id, domain_check_id: check_id}
      |> Ravner.Workers.HeartbeatWorker.new()
    end)
    |> Oban.insert_all()

    :ok
  end
end
