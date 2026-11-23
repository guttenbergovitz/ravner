defmodule Ravner.Workers.DispatchersTest do
  use Ravner.DataCase, async: true

  alias Ravner.Domains
  alias Ravner.DomainsFixtures
  alias Ravner.Repo
  alias Ravner.Uptime.HeartbeatCheck

  alias Ravner.Workers.{
    A11yScanDispatcher,
    DnsxScanDispatcher,
    DomainCheckDispatcher,
    HeartbeatDispatcher,
    HeartbeatRetentionWorker,
    HttpxScanDispatcher,
    LighthouseScanDispatcher,
    SecurityScanDispatcher,
    SslCheckDispatcher
  }

  describe "cron scan dispatchers" do
    test "A11yScanDispatcher executes cleanly when domains have a11y scheduling enabled" do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})

      {:ok, _} =
        Domains.upsert_domain_metadata(domain.id, %{
          http_status: 200,
          a11y_scan_interval_days: 7,
          last_a11y_scan_at: nil
        })

      assert :ok = A11yScanDispatcher.perform(%Oban.Job{args: %{}})
    end

    test "LighthouseScanDispatcher executes cleanly when domains have lighthouse scheduling enabled" do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})

      {:ok, _} =
        Domains.upsert_domain_metadata(domain.id, %{
          http_status: 200,
          lighthouse_scan_interval_days: 7,
          last_lighthouse_scan_at: nil
        })

      assert :ok = LighthouseScanDispatcher.perform(%Oban.Job{args: %{}})
    end

    test "DnsxScanDispatcher, HttpxScanDispatcher, SslCheckDispatcher, and SecurityScanDispatcher execute cleanly" do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})

      {:ok, _} =
        Domains.upsert_domain_metadata(domain.id, %{
          dns_scan_interval_days: 7,
          http_scan_interval_days: 7,
          ssl_check_interval_days: 7,
          scan_interval_days: 7
        })

      assert :ok = DnsxScanDispatcher.perform(%Oban.Job{args: %{}})
      assert :ok = HttpxScanDispatcher.perform(%Oban.Job{args: %{}})
      assert :ok = SslCheckDispatcher.perform(%Oban.Job{args: %{}})
      assert :ok = SecurityScanDispatcher.perform(%Oban.Job{args: %{}})
    end

    test "HeartbeatDispatcher and DomainCheckDispatcher execute cleanly" do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})

      {:ok, _} =
        Domains.upsert_domain_metadata(domain.id, %{
          heartbeat_interval_minutes: 5,
          last_heartbeat_at: nil
        })

      assert :ok = HeartbeatDispatcher.perform(%Oban.Job{args: %{}})
      assert :ok = DomainCheckDispatcher.perform(%Oban.Job{args: %{}})
    end

    test "HeartbeatRetentionWorker prunes heartbeat checks older than 90 days" do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :active})
      old_date = DateTime.add(DateTime.utc_now(:second), -100, :day)
      recent_date = DateTime.add(DateTime.utc_now(:second), -5, :day)

      old_check =
        Repo.insert!(%HeartbeatCheck{
          domain_id: domain.id,
          is_up: true,
          response_time_ms: 42,
          checked_at: old_date
        })

      recent_check =
        Repo.insert!(%HeartbeatCheck{
          domain_id: domain.id,
          is_up: true,
          response_time_ms: 35,
          checked_at: recent_date
        })

      assert :ok = HeartbeatRetentionWorker.perform(%Oban.Job{args: %{}})

      assert Repo.get(HeartbeatCheck, old_check.id) == nil
      assert Repo.get(HeartbeatCheck, recent_check.id) != nil
    end
  end
end
