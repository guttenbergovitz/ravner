defmodule Ravner.Workers.HeartbeatDispatcher do
  @moduledoc """
  Dispatches HeartbeatWorker jobs for domains that are due for a check.
  """
  use Oban.Worker, queue: :default

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Domains.DomainMetadata

  @impl Oban.Worker
  def perform(_job) do
    # Find domains where heartbeat_interval_minutes is not null AND
    # (last_heartbeat_at is null OR last_heartbeat_at + interval < NOW())

    query =
      from(m in DomainMetadata,
        where: not is_nil(m.heartbeat_interval_minutes),
        where:
          is_nil(m.last_heartbeat_at) or
            fragment(
              "? + ? * interval '1 minute' < ?",
              m.last_heartbeat_at,
              m.heartbeat_interval_minutes,
              from_now(0, "second")
            ),
        select: m.domain_id
      )

    query
    |> Repo.all()
    |> Enum.map(fn id ->
      %{domain_id: id}
      |> Ravner.Workers.HeartbeatWorker.new()
    end)
    |> Oban.insert_all()

    :ok
  end
end
