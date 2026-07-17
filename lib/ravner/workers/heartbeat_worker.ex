defmodule Ravner.Workers.HeartbeatWorker do
  @moduledoc """
  HTTP HEAD/GET ping to determine if a domain or custom check URL is up.
  Uses Req (pure Elixir) — no external binary dependency.

  Accepts two modes:
  - Domain heartbeat: args = %{"domain_id" => id} — pings https://domain.name
  - Custom check: args = %{"domain_id" => id, "domain_check_id" => id} — pings check.url
  """
  use Oban.Worker, queue: :heartbeats

  alias Ravner.Domains
  alias Ravner.Uptime
  alias Ravner.Repo

  # ponytail: 5s connect + 5s receive is generous for a heartbeat.
  # Upgrade path: per-domain timeout config if needed.
  @req_options [connect_options: [timeout: 5_000], receive_timeout: 5_000, max_redirects: 5]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain_id" => domain_id} = args}) do
    domain_check_id = args["domain_check_id"]
    target = resolve_target(domain_id, domain_check_id)

    started_at = System.monotonic_time(:millisecond)

    {is_up, error_reason} = run_check(target)

    elapsed = System.monotonic_time(:millisecond) - started_at
    response_time_ms = if is_up, do: elapsed, else: nil
    now = DateTime.utc_now(:second)

    Uptime.record_check(domain_id, %{
      is_up: is_up,
      checked_at: now,
      response_time_ms: response_time_ms,
      error_reason: error_reason,
      domain_check_id: domain_check_id
    })

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
    # Domain names are stored without scheme — prepend https
    url = domain.name
    if String.starts_with?(url, "http"), do: url, else: "https://#{url}"
  end

  defp resolve_target(_domain_id, check_id) do
    Repo.get!(Ravner.Uptime.DomainCheck, check_id).url
  end

  defp run_check(url) do
    case Req.head(url, @req_options) do
      {:ok, %Req.Response{status: status}} when status < 400 ->
        {true, nil}

      {:ok, %Req.Response{status: status}} ->
        {false, "http_#{status}"}

      {:error, %Mint.TransportError{reason: reason}} ->
        {false, to_string(reason)}

      {:error, exception} ->
        {false, Exception.message(exception)}
    end
  end

  defp update_check_state(check_id, is_up, now) do
    import Ecto.Query

    from(c in Ravner.Uptime.DomainCheck, where: c.id == ^check_id)
    |> Repo.update_all(set: [is_up: is_up, last_checked_at: now])
  end
end
