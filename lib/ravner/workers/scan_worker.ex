defmodule Ravner.Workers.ScanWorker do
  @moduledoc """
  Executes heavy scans using Oban to control concurrency.
  """
  use Oban.Worker, queue: :scans

  alias Ravner.Scans.SecurityRunner
  alias Ravner.Scans
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain_id" => domain_id, "scan_type" => "security_scan"}}) do
    Logger.info("Starting background security scan for domain #{domain_id}")

    # We pass nil for liveview_pid because this is a background job without a connected UI.
    case SecurityRunner.run_security_scan(domain_id, nil) do
      {:ok, _scan} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"domain_id" => domain_id, "scan_type" => "httpx"}}) do
    Logger.info("Starting background HTTPX scan for domain #{domain_id}")
    Scans.Http.run_httpx_scan(domain_id)
    :ok
  end

  def perform(%Oban.Job{args: %{"domain_id" => domain_id, "scan_type" => "dnsx"}}) do
    Logger.info("Starting background DNSX scan for domain #{domain_id}")
    Scans.Dns.run(domain_id)
    :ok
  end

  def perform(%Oban.Job{args: %{"domain_id" => domain_id, "scan_type" => "ssl"}}) do
    Logger.info("Starting background SSL scan for domain #{domain_id}")
    Scans.Ssl.run(domain_id)
    :ok
  end

  def perform(%Oban.Job{args: %{"domain_id" => domain_id, "scan_type" => "rdap"}}) do
    Logger.info("Starting background RDAP scan for domain #{domain_id}")
    Scans.Whois.run_rdap_scan(domain_id)
    :ok
  end

  def perform(%Oban.Job{args: %{"scan_type" => type}}) do
    {:error, "Unknown scan type: #{type}"}
  end
end
