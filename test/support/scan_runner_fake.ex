defmodule Ravner.TestSupport.ScanRunnerFake do
  def run_scan(domain_id) do
    Ravner.ActivityLog.emit(:step, "Scanning domain #{domain_id}…")
    Application.fetch_env!(:ravner, :scan_runner_fake_result)
  end

  def run_quick_scan(domain_id) do
    Ravner.ActivityLog.emit(:step, "Quick scanning domain #{domain_id}…")
    Application.fetch_env!(:ravner, :scan_runner_fake_result)
  end
end
