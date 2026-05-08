defmodule Ravner.Workers.SslCheckDispatcher do
  @moduledoc """
  Dispatches SslCheckWorker jobs.
  """
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(_job) do
    # Find domains where ssl_check_interval_days is not null AND
    # (ssl_scanned_at is null OR ssl_scanned_at + interval < NOW())
    # Note: We can implement this fully later, just placeholder for architecture completeness.
    :ok
  end
end
