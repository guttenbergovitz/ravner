defmodule Ravner.Workers.ScanWorkerErrorTest do
  use ExUnit.Case, async: false

  alias Ravner.TestSupport.ScanRunnerFake
  alias Ravner.Workers.{A11yScanWorker, LighthouseScanWorker, ScanWorker}

  setup do
    original_a11y = Application.get_env(:ravner, :a11y_scan_runner)
    original_lighthouse = Application.get_env(:ravner, :lighthouse_scan_runner)

    Application.put_env(:ravner, :a11y_scan_runner, ScanRunnerFake)
    Application.put_env(:ravner, :lighthouse_scan_runner, ScanRunnerFake)
    original_quick = Application.get_env(:ravner, :quick_scan_runner)
    Application.put_env(:ravner, :quick_scan_runner, ScanRunnerFake)

    on_exit(fn ->
      restore_env(:a11y_scan_runner, original_a11y)
      restore_env(:lighthouse_scan_runner, original_lighthouse)
      restore_env(:quick_scan_runner, original_quick)
      Application.delete_env(:ravner, :scan_runner_fake_result)
    end)

    :ok
  end

  test "a11y worker retries scanner errors" do
    Application.put_env(:ravner, :scan_runner_fake_result, {:error, :scanner_down})

    assert {:error, :scanner_down} = A11yScanWorker.perform(job())
  end

  test "lighthouse worker retries scanner errors" do
    Application.put_env(:ravner, :scan_runner_fake_result, {:error, :scanner_down})

    assert {:error, :scanner_down} = LighthouseScanWorker.perform(job())
  end

  test "scanner eligibility errors are terminal successes" do
    Application.put_env(:ravner, :scan_runner_fake_result, {:error, :not_scannable})

    assert :ok = A11yScanWorker.perform(job())
    assert :ok = LighthouseScanWorker.perform(job())
  end

  test "successful scanner runs complete the job" do
    Application.put_env(:ravner, :scan_runner_fake_result, {:ok, %{id: 1}})

    assert :ok = A11yScanWorker.perform(job())
    assert :ok = LighthouseScanWorker.perform(job())
  end

  test "quick scan publishes successful completion" do
    Application.put_env(:ravner, :scan_runner_fake_result, {:ok, %{id: 1}})
    topic = "test:scan:#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Ravner.PubSub, topic)

    assert :ok =
             ScanWorker.perform(%Oban.Job{
               args: %{"domain_id" => 42, "scan_type" => "quick", "notify_topic" => topic}
             })

    assert_receive {:bulk_scan_done, 42, "quick", :ok}
  end

  test "quick scan publishes failed completion and returns the error" do
    Application.put_env(:ravner, :scan_runner_fake_result, {:error, :scanner_down})
    topic = "test:scan:#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Ravner.PubSub, topic)

    assert {:error, :scanner_down} =
             ScanWorker.perform(%Oban.Job{
               args: %{"domain_id" => 42, "scan_type" => "quick", "notify_topic" => topic}
             })

    assert_receive {:bulk_scan_done, 42, "quick", :error}
  end

  test "quick scan worker sets ActivityLog user from user_id or notify_topic" do
    Application.put_env(:ravner, :scan_runner_fake_result, {:ok, %{id: 1}})
    user_id = System.unique_integer([:positive])
    Ravner.ActivityLog.subscribe(user_id)

    assert :ok =
             ScanWorker.perform(%Oban.Job{
               args: %{
                 "domain_id" => 42,
                 "scan_type" => "quick",
                 "notify_topic" => "bulk_scans:user:#{user_id}",
                 "user_id" => user_id
               }
             })

    assert_receive {:activity, :step, "Quick scanning domain 42…", _ts}
  end

  test "a11y and lighthouse workers set ActivityLog user from user_id" do
    Application.put_env(:ravner, :scan_runner_fake_result, {:ok, %{id: 1}})
    user_id = System.unique_integer([:positive])
    Ravner.ActivityLog.subscribe(user_id)

    assert :ok =
             A11yScanWorker.perform(%Oban.Job{
               args: %{"domain_id" => 77, "user_id" => user_id}
             })

    assert_receive {:activity, :step, "Scanning domain 77…", _ts}

    assert :ok =
             LighthouseScanWorker.perform(%Oban.Job{
               args: %{"domain_id" => 88, "user_id" => user_id}
             })

    assert_receive {:activity, :step, "Scanning domain 88…", _ts}
  end

  defp job, do: %Oban.Job{args: %{"domain_id" => 42}}

  defp restore_env(key, nil), do: Application.delete_env(:ravner, key)
  defp restore_env(key, value), do: Application.put_env(:ravner, key, value)
end
