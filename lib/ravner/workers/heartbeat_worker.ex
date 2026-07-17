defmodule Ravner.Workers.HeartbeatWorker do
  @moduledoc """
  A fast HTTP GET/HEAD ping to determine if a domain or custom check URL is up.
  Persists result to heartbeat_checks and evaluates downtime state.

  Accepts two modes:
  - Domain heartbeat: args = %{"domain_id" => id} — pings domain.name
  - Custom check: args = %{"domain_id" => id, "domain_check_id" => id} — pings check.url
  """
  use Oban.Worker, queue: :heartbeats

  alias Ravner.Domains
  alias Ravner.Uptime
  alias Ravner.Repo
  alias Ravner.SystemCommand
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain_id" => domain_id} = args}) do
    domain_check_id = args["domain_check_id"]
    target = resolve_target(domain_id, domain_check_id)

    started_at = System.monotonic_time(:millisecond)

    {is_up, error_reason} = run_check(target)

    elapsed = System.monotonic_time(:millisecond) - started_at
    response_time_ms = if is_up, do: elapsed, else: nil
    now = DateTime.utc_now(:second)

    # Persist to heartbeat_checks + evaluate downtime
    Uptime.record_check(domain_id, %{
      is_up: is_up,
      checked_at: now,
      response_time_ms: response_time_ms,
      error_reason: error_reason,
      domain_check_id: domain_check_id
    })

    # Update last state
    if domain_check_id do
      update_check_state(domain_check_id, is_up, now)
    else
      Domains.upsert_domain_metadata(domain_id, %{
        is_up: is_up,
        last_heartbeat_at: now
      })
    end

    :ok
  end

  defp resolve_target(domain_id, nil) do
    domain = Domains.get_domain!(domain_id)
    domain.name
  end

  defp resolve_target(_domain_id, check_id) do
    check = Repo.get!(Ravner.Uptime.DomainCheck, check_id)
    check.url
  end

  defp run_check(target) do
    args = [
      "-silent",
      "-no-color",
      "-status-code",
      "-timeout",
      "5",
      "-u",
      target
    ]

    case SystemCommand.run_with_timeout("httpx", args, 10_000) do
      {output, 0} ->
        output = String.trim(output)

        cond do
          output == "" ->
            {false, "no_response"}

          String.match?(output, ~r/\[200\]|\[30[0-9]\]/) ->
            {true, nil}

          match = Regex.run(~r/\[(\d+)\]/, output) ->
            {false, "http_#{Enum.at(match, 1)}"}

          true ->
            {false, "unexpected_output"}
        end

      {_output, code} ->
        {false, "exit_code_#{code}"}

      {:error, :timeout} ->
        {false, "timeout"}

      {:error, reason} ->
        {false, "error_#{inspect(reason)}"}
    end
  end

  defp update_check_state(check_id, is_up, now) do
    import Ecto.Query

    from(c in Ravner.Uptime.DomainCheck, where: c.id == ^check_id)
    |> Repo.update_all(set: [is_up: is_up, last_checked_at: now])
  end
end
