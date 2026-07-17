defmodule Ravner.Workers.HeartbeatWorker do
  @moduledoc """
  A fast HTTP GET/HEAD ping to determine if a domain is up.
  Persists result to heartbeat_checks and evaluates downtime state.
  """
  use Oban.Worker, queue: :heartbeats

  alias Ravner.Domains
  alias Ravner.Uptime
  alias Ravner.SystemCommand
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain_id" => domain_id}}) do
    domain = Domains.get_domain!(domain_id)
    started_at = System.monotonic_time(:millisecond)

    args = [
      "-silent",
      "-no-color",
      "-status-code",
      "-timeout",
      "5",
      "-u",
      domain.name
    ]

    {is_up, error_reason} =
      case SystemCommand.run_with_timeout("httpx", args, 10_000) do
        {:ok, %{exit_code: 0, output: output}} ->
          if String.match?(output, ~r/\[200\]|\[30[0-9]\]/) do
            {true, nil}
          else
            {false, "unexpected_status"}
          end

        {:ok, %{exit_code: code}} ->
          {false, "exit_code_#{code}"}

        {:error, :timeout} ->
          {false, "timeout"}

        {:error, reason} ->
          {false, "error_#{inspect(reason)}"}
      end

    elapsed = System.monotonic_time(:millisecond) - started_at
    response_time_ms = if is_up, do: elapsed, else: nil
    now = DateTime.utc_now(:second)

    # Persist to heartbeat_checks + evaluate downtime
    Uptime.record_check(domain_id, %{
      is_up: is_up,
      checked_at: now,
      response_time_ms: response_time_ms,
      error_reason: error_reason
    })

    # Keep backward compat: update domain_metadata
    Domains.upsert_domain_metadata(domain_id, %{
      is_up: is_up,
      last_heartbeat_at: now
    })

    :ok
  end
end
