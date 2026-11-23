defmodule Ravner.ScanConfigTest do
  use Ravner.DataCase, async: false

  alias Ravner.ScanConfig

  describe "scan_config" do
    test "get/0 returns the singleton config row with default light mode" do
      config = ScanConfig.get()
      assert config.security_scan_mode == "light"
      assert config.security_scanner in ["nuclei", "lonkero"]
    end

    test "update/1 updates security_scan_mode to heavy and back to light" do
      assert {:ok, config} = ScanConfig.update(%{security_scan_mode: "heavy"})
      assert config.security_scan_mode == "heavy"

      assert {:ok, config} = ScanConfig.update(%{security_scan_mode: "light"})
      assert config.security_scan_mode == "light"
    end

    test "changeset/2 rejects invalid security_scan_mode" do
      config = ScanConfig.get()
      changeset = ScanConfig.changeset(config, %{security_scan_mode: "invalid_mode"})
      refute changeset.valid?
      assert %{security_scan_mode: ["is invalid"]} = errors_on(changeset)
    end
  end
end
