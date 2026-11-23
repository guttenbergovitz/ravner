defmodule Ravner.Workers.WorkerConfigurationTest do
  use ExUnit.Case, async: true

  alias Ravner.Workers.{DomainCheckDispatcher, HeartbeatWorker, ScanWorker}

  test "heartbeat jobs are unique per domain and custom check" do
    opts = HeartbeatWorker.__opts__()

    assert opts[:queue] == :heartbeats

    assert opts[:unique] == [
             period: 120,
             fields: [:args],
             keys: [:domain_id, :domain_check_id]
           ]
  end

  test "domain-check dispatchers are deduplicated during cron overlap" do
    opts = DomainCheckDispatcher.__opts__()

    assert opts[:queue] == :default
    assert opts[:unique] == [period: 120, fields: [:args]]
  end

  test "unknown scan types fail explicitly" do
    assert {:error, "Unknown scan type: unsupported"} =
             ScanWorker.perform(%Oban.Job{args: %{"scan_type" => "unsupported"}})
  end

  test "scan jobs are unique per domain and scan type" do
    opts = ScanWorker.__opts__()

    assert opts[:queue] == :scans

    assert opts[:unique] == [
             period: 1_800,
             states: :incomplete,
             fields: [:args],
             keys: [:domain_id, :scan_type]
           ]
  end
end
