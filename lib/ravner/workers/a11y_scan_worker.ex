defmodule Ravner.Workers.A11yScanWorker do
  @moduledoc """
  Oban worker for background accessibility scans via pa11y.
  """
  use Oban.Worker, queue: :scans, max_attempts: 2

  alias Ravner.A11y

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain_id" => domain_id}}) do
    case A11y.run_scan(domain_id) do
      {:ok, _scan} -> :ok
      {:error, :not_scannable} -> :ok
      {:error, _} -> :ok
    end
  end
end
