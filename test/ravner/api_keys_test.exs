defmodule Ravner.ApiKeysTest do
  use Ravner.DataCase, async: false

  alias Ravner.ApiKeys

  describe "known keys" do
    test "lists only active integrations and excludes vestigial keys" do
      known = ApiKeys.list_known_keys()
      names = Enum.map(known, & &1.name)

      assert "chaos" in names
      assert "lonkero" in names
      refute "securitytrails" in names
      refute "shodan" in names
    end
  end

  describe "get_effective_key/1" do
    test "retrieves decrypted key when stored in database settings" do
      {:ok, api_key} =
        ApiKeys.create_api_key(%{
          name: "chaos",
          key: "test_secret_chaos_key_123"
        })

      assert {:settings, "test_secret_chaos_key_123", _} = ApiKeys.get_effective_key("chaos")
      assert ApiKeys.key_configured?("chaos") == true
      assert ApiKeys.get_key_source("chaos") == :settings

      ApiKeys.delete_api_key(api_key)
    end

    test "falls back to environment variable when not in database" do
      System.put_env("CHAOS_API_KEY", "env_secret_chaos_456")

      on_exit(fn ->
        System.delete_env("CHAOS_API_KEY")
      end)

      assert {:env, "env_secret_chaos_456", nil} = ApiKeys.get_effective_key("chaos")
      assert ApiKeys.key_configured?("chaos") == true
      assert ApiKeys.get_key_source("chaos") == :env
    end

    test "returns :none when neither settings nor env is configured" do
      System.delete_env("CHAOS_API_KEY")
      assert {:none, nil, nil} = ApiKeys.get_effective_key("chaos")
      assert ApiKeys.key_configured?("chaos") == false
      assert ApiKeys.get_key_source("chaos") == :none
    end
  end
end
