defmodule Ravner.Workers.LighthouseScanWorker do
  @moduledoc """
  Oban worker for background Lighthouse PageSpeed scans.
  """
  use Oban.Worker, queue: :scans, max_attempts: 2

  alias Ravner.Lighthouse

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain_id" => domain_id} = args}) do
    if args["user_id"], do: Ravner.ActivityLog.set_user(args["user_id"])
    runner = Application.get_env(:ravner, :lighthouse_scan_runner, Lighthouse)

    case runner.run_scan(domain_id) do
      {:ok, _scan} -> :ok
      {:error, :not_scannable} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
