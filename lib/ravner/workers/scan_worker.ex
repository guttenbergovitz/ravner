defmodule Ravner.Workers.ScanWorker do
  @moduledoc """
  Executes heavy scans using Oban to control concurrency.
  """
  use Oban.Worker,
    queue: :scans,
    max_attempts: 3,
    unique: [
      period: 1_800,
      states: :incomplete,
      fields: [:args],
      keys: [:domain_id, :scan_type]
    ]

  alias Ravner.Scans.SecurityRunner
  alias Ravner.Scans
  require Logger

  @impl Oban.Worker
  def perform(
        %Oban.Job{args: %{"domain_id" => domain_id, "scan_type" => "security_scan"} = args} = job
      ) do
    maybe_set_activity_user(args)
    Logger.info("Starting background security scan for domain #{domain_id}")

    SecurityRunner.run_security_scan_sync(domain_id, resolve_user_id(args))
    |> finish_scan(job, args)
  end

  def perform(%Oban.Job{args: %{"domain_id" => domain_id, "scan_type" => "quick"} = args} = job) do
    maybe_set_activity_user(args)
    runner = Application.get_env(:ravner, :quick_scan_runner, Scans)

    runner.run_quick_scan(domain_id)
    |> finish_scan(job, args)
  end

  def perform(%Oban.Job{
        args: %{"domain_id" => domain_id, "scan_type" => "security_scan_heavy"} = args
      }) do
    maybe_set_activity_user(args)
    Logger.info("Starting background HEAVY security scan for domain #{domain_id}")

    SecurityRunner.run_security_scan_sync(domain_id, resolve_user_id(args), :heavy)
    |> finish_result()
  end

  def perform(%Oban.Job{args: %{"domain_id" => domain_id, "scan_type" => "httpx"} = args}) do
    maybe_set_activity_user(args)
    Logger.info("Starting background HTTPX scan for domain #{domain_id}")
    Scans.Http.run_httpx_scan(domain_id) |> finish_result()
  end

  def perform(%Oban.Job{args: %{"domain_id" => domain_id, "scan_type" => "dnsx"} = args}) do
    maybe_set_activity_user(args)
    Logger.info("Starting background DNSX scan for domain #{domain_id}")
    Scans.Dns.run(domain_id) |> finish_result()
  end

  def perform(%Oban.Job{args: %{"domain_id" => domain_id, "scan_type" => "ssl"} = args}) do
    maybe_set_activity_user(args)
    Logger.info("Starting background SSL scan for domain #{domain_id}")
    Scans.Ssl.run(domain_id) |> finish_result()
  end

  def perform(%Oban.Job{args: %{"domain_id" => domain_id, "scan_type" => "rdap"} = args}) do
    maybe_set_activity_user(args)
    Logger.info("Starting background RDAP scan for domain #{domain_id}")
    Scans.Whois.run_rdap_scan(domain_id) |> finish_result()
  end

  def perform(%Oban.Job{args: %{"scan_type" => type}}) do
    {:error, "Unknown scan type: #{type}"}
  end

  defp resolve_user_id(%{"user_id" => user_id}) when not is_nil(user_id), do: user_id

  defp resolve_user_id(%{"notify_topic" => "bulk_scans:user:" <> user_id}) do
    case Integer.parse(user_id) do
      {id, ""} -> id
      _ -> user_id
    end
  end

  defp resolve_user_id(_args), do: nil

  defp maybe_set_activity_user(args) do
    case resolve_user_id(args) do
      nil -> :ok
      user_id -> Ravner.ActivityLog.set_user(user_id)
    end
  end

  defp finish_scan({:ok, _result}, _job, args) do
    notify(args, :ok)
    :ok
  end

  defp finish_scan({:error, reason}, _job, args) do
    notify(args, :error)
    {:error, reason}
  end

  # Quick scan returns raw map, not {:ok, ...} tuple
  defp finish_scan(%{} = _result, _job, args) do
    notify(args, :ok)
    :ok
  end

  defp finish_result({:ok, _result}), do: :ok
  defp finish_result({:error, :not_scannable}), do: :ok
  defp finish_result({:error, reason}), do: {:error, reason}

  defp notify(
         %{"notify_topic" => topic, "domain_id" => domain_id, "scan_type" => scan_type},
         status
       ) do
    Phoenix.PubSub.broadcast(
      Ravner.PubSub,
      topic,
      {:bulk_scan_done, domain_id, scan_type, status}
    )
  end

  defp notify(_args, _status), do: :ok
end
