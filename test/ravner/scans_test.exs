defmodule Ravner.ScansTest do
  use ExUnit.Case, async: false

  alias Ravner.Scans

  setup do
    original = Application.get_env(:ravner, :scan_max_concurrency)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:ravner, :scan_max_concurrency)
      else
        Application.put_env(:ravner, :scan_max_concurrency, original)
      end
    end)

    :ok
  end

  test "scan_max_concurrency returns configured positive integer" do
    Application.put_env(:ravner, :scan_max_concurrency, 3)

    assert Scans.scan_max_concurrency() == 3
  end

  test "scan_max_concurrency defaults to five when config is missing" do
    Application.delete_env(:ravner, :scan_max_concurrency)

    assert Scans.scan_max_concurrency() == 5
  end

  test "scan_max_concurrency falls back to five for invalid config" do
    Application.put_env(:ravner, :scan_max_concurrency, 0)

    assert Scans.scan_max_concurrency() == 5
  end
end
