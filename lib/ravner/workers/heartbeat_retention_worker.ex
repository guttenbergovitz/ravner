defmodule Ravner.Workers.HeartbeatRetentionWorker do
  @moduledoc """
  Prunes heartbeat_checks older than the configured retention period.
  Runs daily at 04:00 UTC.
  """
  use Oban.Worker, queue: :default

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Uptime.HeartbeatCheck

  require Logger

  # ponytail: retention days hardcoded; upgrade path: app config or admin setting
  @retention_days 90

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)

    {deleted, _} =
      HeartbeatCheck
      |> where([c], c.checked_at < ^cutoff)
      |> Repo.delete_all()

    if deleted > 0 do
      Logger.info("[HeartbeatRetention] Pruned #{deleted} checks older than #{@retention_days}d")
    end

    :ok
  end
end
