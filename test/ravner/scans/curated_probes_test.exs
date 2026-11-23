defmodule Ravner.Scans.CuratedProbesTest do
  use ExUnit.Case, async: true

  alias Ravner.Scans.CuratedProbes

  describe "probes/0" do
    test "returns curated catalogue of high-value probes" do
      probes = CuratedProbes.probes()
      assert is_list(probes)
      assert length(probes) >= 30

      paths = Enum.map(probes, & &1.path)
      assert "/.env" in paths
      assert "/.git/HEAD" in paths
      assert "/actuator/env" in paths
      assert "/phpinfo.php" in paths
      assert "/swagger-ui/index.html" in paths
      assert "/.aws/credentials" in paths
      assert "/dump.sql" in paths
      assert "/docker-compose.yml" in paths
    end

    test "all probes define required attributes" do
      for probe <- CuratedProbes.probes() do
        assert is_binary(probe.path)
        assert String.starts_with?(probe.path, "/")
        assert is_binary(probe.title)
        assert probe.severity in ["critical", "high", "medium", "low", "info"]
        assert is_binary(probe.category)
        assert is_binary(probe.description)
        assert is_list(probe.references)
      end
    end
  end

  describe "probe/2 pattern matching" do
    test "matches .env probe and rejects soft-404 HTML responses" do
      env_probe = Enum.find(CuratedProbes.probes(), &(&1.path == "/.env"))
      assert env_probe != nil

      # Mock server behavior using custom plug or testing probe list
      # Verify pattern matches actual .env content
      content = "APP_NAME=Laravel\nAPP_KEY=base64:abcd\nDB_PASSWORD=secret123\n"
      assert Regex.match?(env_probe.pattern, content)

      # Verify anti-pattern blocks soft 404 HTML
      soft_404 = "<!DOCTYPE html><html><body>404 Not Found</body></html>"
      assert Enum.any?(env_probe.anti_patterns, &Regex.match?(&1, soft_404))
    end

    test "matches .git/HEAD probe ref structure" do
      git_probe = Enum.find(CuratedProbes.probes(), &(&1.path == "/.git/HEAD"))
      assert git_probe != nil

      valid_head = "ref: refs/heads/main\n"
      assert Regex.match?(git_probe.pattern, valid_head)

      invalid_head = "Some other text"
      refute Regex.match?(git_probe.pattern, invalid_head)
    end

    test "matches Spring actuator/env response" do
      actuator_probe = Enum.find(CuratedProbes.probes(), &(&1.path == "/actuator/env"))
      assert actuator_probe != nil

      valid_actuator = ~s|{"activeProfiles":["prod"],"propertySources":[]}|
      assert Regex.match?(actuator_probe.pattern, valid_actuator)
    end
  end
end
