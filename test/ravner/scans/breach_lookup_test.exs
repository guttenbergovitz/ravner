defmodule Ravner.Scans.BreachLookupTest do
  use ExUnit.Case, async: true

  alias Ravner.Scans.BreachLookup

  describe "calculate_heat/3" do
    test "returns :clean when no compromises and no date" do
      assert {:clean, label, nil} = BreachLookup.calculate_heat(nil, nil, 0)
      assert label =~ "Clean"
    end

    test "returns :hot when compromise is within last 30 days" do
      recent_date =
        DateTime.utc_now()
        |> DateTime.add(-5, :day)
        |> DateTime.to_iso8601()

      assert {:hot, label, 5} = BreachLookup.calculate_heat(recent_date, nil, 10)
      assert label =~ "Hot & Active"
    end

    test "returns :recent when compromise is between 31 and 180 days ago" do
      recent_date =
        DateTime.utc_now()
        |> DateTime.add(-60, :day)
        |> DateTime.to_iso8601()

      assert {:recent, label, 60} = BreachLookup.calculate_heat(recent_date, nil, 4)
      assert label =~ "Recent"
    end

    test "returns :historical when compromise is over 180 days ago" do
      old_date =
        DateTime.utc_now()
        |> DateTime.add(-250, :day)
        |> DateTime.to_iso8601()

      assert {:historical, label, 250} = BreachLookup.calculate_heat(old_date, nil, 2)
      assert label =~ "Historical"
    end
  end

  describe "lookup/2 with mocked responses" do
    test "processes clean domain with zero compromises" do
      mock_req = fn _domain, _opts ->
        body = %{
          "total" => 0,
          "employees" => 0,
          "users" => 0,
          "third_parties" => 0
        }

        {:ok, %{status: 200, body: body}}
      end

      assert {:ok, stats, findings} = BreachLookup.lookup("example.com", req_fun: mock_req)
      assert stats.total == 0
      assert stats.employees == 0
      assert stats.heat == :clean
      assert findings == []
    end

    test "processes hot employee compromise with critical finding and metadata" do
      hot_date =
        DateTime.utc_now()
        |> DateTime.add(-3, :day)
        |> DateTime.to_iso8601()

      mock_req = fn _domain, _opts ->
        body = %{
          "total" => 540,
          "employees" => 12,
          "users" => 528,
          "third_parties" => 0,
          "last_employee_compromised" => hot_date,
          "stealerFamilies" => %{
            "total" => 540,
            "RedLine" => 350,
            "Vidar" => 150,
            "Raccoon" => 40
          },
          "data" => %{
            "employees_urls" => [
              %{"url" => "https://vpn.example.com", "occurrence" => 12},
              %{"url" => "https://mail.example.com", "occurrence" => 8}
            ]
          }
        }

        {:ok, %{status: 200, body: body}}
      end

      assert {:ok, stats, [finding]} =
               BreachLookup.lookup("https://example.com/login", req_fun: mock_req)

      assert stats.employees == 12
      assert stats.heat == :hot
      assert stats.days_ago == 3
      assert stats.stealer_families == ["RedLine", "Vidar", "Raccoon"]
      assert stats.targeted_urls == ["https://vpn.example.com", "https://mail.example.com"]

      assert finding.severity == "critical"
      assert finding.title =~ "ACTIVE / HOT"
      assert finding.title =~ "12 corporate employee credentials leaked"
      assert finding.detail["heat"] == "hot"
      assert finding.detail["employees_count"] == 12
      assert finding.detail["stealer_families"] == ["RedLine", "Vidar", "Raccoon"]

      assert finding.detail["targeted_urls"] == [
               "https://vpn.example.com",
               "https://mail.example.com"
             ]

      assert finding.detail["source"] == "hudson_rock"
    end

    test "treats 404 from Hudson Rock as clean domain" do
      mock_req = fn _domain, _opts ->
        {:ok, %{status: 404, body: ""}}
      end

      assert {:ok, stats, []} = BreachLookup.lookup("unknown-fresh-domain.org", req_fun: mock_req)
      assert stats.heat == :clean
      assert stats.total == 0
    end

    test "handles connection errors safely" do
      mock_req = fn _domain, _opts ->
        {:error, :timeout}
      end

      assert {:error, msg} = BreachLookup.lookup("example.com", req_fun: mock_req)
      assert msg =~ "Failed to connect"
    end
  end
end
