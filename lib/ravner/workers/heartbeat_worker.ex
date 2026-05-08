defmodule Ravner.Workers.HeartbeatWorker do
  @moduledoc """
  A fast HTTP GET/HEAD ping to determine if a domain is up.
  """
  use Oban.Worker, queue: :heartbeats

  alias Ravner.Domains
  alias Ravner.SystemCommand
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain_id" => domain_id}}) do
    domain = Domains.get_domain!(domain_id)

    # Simple fast ping using httpx for reliability (or could use native HTTP client like Req)
    # Using httpx to leverage our existing boundary and timeout rules.
    args = [
      "-silent",
      "-status-code",
      "-timeout",
      "5",
      "-u",
      domain.name
    ]

    is_up =
      case SystemCommand.run_with_timeout("httpx", args, 10_000) do
        {:ok, %{exit_code: 0, output: output}} ->
          String.match?(output, ~r/\[200\]|\[30[0-9]\]/)

        _ ->
          false
      end

    Domains.upsert_domain_metadata(domain_id, %{
      is_up: is_up,
      last_heartbeat_at: DateTime.utc_now()
    })

    :ok
  end
end
