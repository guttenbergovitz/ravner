defmodule Ravner.UptimeTest do
  use Ravner.DataCase, async: true

  import Ravner.DomainsFixtures

  alias Ravner.Uptime
  alias Ravner.Uptime.DowntimeWindow

  describe "record_check/2 downtime detection" do
    setup do
      domain = domain_fixture(%{name: "uptime-test-#{System.unique_integer([:positive])}.com"})
      %{domain: domain}
    end

    test "does not open downtime on first failure", %{domain: domain} do
      Uptime.record_check(domain.id, %{is_up: false, checked_at: DateTime.utc_now()})
      assert Repo.aggregate(DowntimeWindow, :count) == 0
    end

    test "opens downtime after 2 consecutive failures (default threshold)", %{domain: domain} do
      now = DateTime.utc_now()
      t1 = DateTime.add(now, -60, :second)
      t2 = now

      Uptime.record_check(domain.id, %{is_up: false, checked_at: t1})
      Uptime.record_check(domain.id, %{is_up: false, checked_at: t2})

      assert [%DowntimeWindow{ended_at: nil}] = Repo.all(DowntimeWindow)
    end

    test "closes downtime on recovery", %{domain: domain} do
      now = DateTime.utc_now()
      t1 = DateTime.add(now, -120, :second)
      t2 = DateTime.add(now, -60, :second)
      t3 = now

      Uptime.record_check(domain.id, %{is_up: false, checked_at: t1})
      Uptime.record_check(domain.id, %{is_up: false, checked_at: t2})
      Uptime.record_check(domain.id, %{is_up: true, checked_at: t3})

      assert [%DowntimeWindow{ended_at: ended}] = Repo.all(DowntimeWindow)
      assert ended != nil
    end

    test "does not open duplicate downtime if already open", %{domain: domain} do
      now = DateTime.utc_now()

      for i <- 0..4 do
        t = DateTime.add(now, -300 + i * 60, :second)
        Uptime.record_check(domain.id, %{is_up: false, checked_at: t})
      end

      assert Repo.aggregate(DowntimeWindow, :count) == 1
    end
  end
end
