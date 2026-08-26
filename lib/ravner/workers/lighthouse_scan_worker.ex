defmodule Ravner.Workers.LighthouseScanWorker do
  @moduledoc """
  Oban worker for background Lighthouse PageSpeed scans.
  """
  use Oban.Worker, queue: :scans, max_attempts: 2

  alias Ravner.Lighthouse

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain_id" => domain_id}}) do
    case Lighthouse.run_scan(domain_id) do
      {:ok, _scan} -> :ok
      {:error, :not_scannable} -> :ok
      {:error, _} -> :ok
    end
  end
end
