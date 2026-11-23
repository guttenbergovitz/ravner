defmodule Ravner.Scans.TechFingerprintTest do
  use ExUnit.Case, async: false

  alias Ravner.Scans.TechFingerprint

  @fixture Path.expand("../../support/fixtures/technologies_test.json", __DIR__)

  setup do
    original = Application.get_env(:ravner, :wappalyzer_technologies_path)
    Application.put_env(:ravner, :wappalyzer_technologies_path, @fixture)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:ravner, :wappalyzer_technologies_path)
      else
        Application.put_env(:ravner, :wappalyzer_technologies_path, original)
      end
    end)

    :ok
  end

  defp response(headers, body) do
    %Req.Response{status: 200, headers: Map.new(headers), body: body}
  end

  test "detects meta generator with version extraction" do
    resp =
      response(
        [],
        ~s(<html><head><meta name="generator" content="WordPress 6.7.1"></head></html>)
      )

    assert {:ok, evidence} = TechFingerprint.analyze("https://example.com", resp)

    assert %{
             "name" => "WordPress",
             "version" => "6.7.1",
             "categories" => ["CMS"],
             "confidence" => 100,
             "source" => "wappalyzer:direct",
             "implied" => false,
             "url" => "https://example.com"
           } = Enum.find(evidence, &(&1["name"] == "WordPress"))
  end

  test "detects from html pattern" do
    resp =
      response([], ~s(<link rel="stylesheet" href="https://example.com/wp-content/themes/x.css">))

    assert {:ok, evidence} = TechFingerprint.analyze("https://example.com", resp)
    assert Enum.find(evidence, &(&1["name"] == "WordPress"))
  end

  test "adds implied technologies" do
    resp =
      response([], ~s(<meta name="generator" content="WordPress 6.7.1">))

    assert {:ok, evidence} = TechFingerprint.analyze("https://example.com", resp)
    names = Enum.map(evidence, & &1["name"])

    assert "PHP" in names
    assert "MySQL" in names

    implied = Enum.find(evidence, &(&1["name"] == "MySQL"))
    assert implied["confidence"] == 50
    assert implied["categories"] == ["Databases"]
    assert implied["source"] == "wappalyzer:implied"
    assert implied["implied"] == true
  end

  test "direct detection wins over implied" do
    resp =
      response(
        [{"x-powered-by", ["PHP/8.3.2"]}],
        ~s(<meta name="generator" content="WordPress 6.7.1">)
      )

    assert {:ok, evidence} = TechFingerprint.analyze("https://example.com", resp)
    php = Enum.find(evidence, &(&1["name"] == "PHP"))

    assert php["version"] == "8.3.2"
    assert php["confidence"] == 100
  end

  test "detects from headers and cookies" do
    resp =
      response(
        [
          {"server", ["cloudflare"]},
          {"set-cookie", ["__cf_bm=abc123; path=/; HttpOnly"]}
        ],
        ""
      )

    assert {:ok, evidence} = TechFingerprint.analyze("https://example.com", resp)
    cf = Enum.find(evidence, &(&1["name"] == "Cloudflare"))
    assert cf["categories"] == ["CDN"]
  end

  test "detects script src with version" do
    resp =
      response([], ~s(<script src="https://cdn.example.com/react-18.3.1.min.js"></script>))

    assert {:ok, evidence} = TechFingerprint.analyze("https://example.com", resp)
    react = Enum.find(evidence, &(&1["name"] == "React"))
    assert react["version"] == "18.3.1"
  end

  test "returns empty list when nothing matches" do
    resp = response([{"server", ["nginx"]}], "<html><body>plain</body></html>")

    assert {:ok, []} = TechFingerprint.analyze("https://example.com", resp)
  end

  test "handles non-binary body" do
    resp = %Req.Response{
      status: 200,
      headers: %{"server" => ["cloudflare"]},
      body: %{"json" => true}
    }

    assert {:ok, evidence} = TechFingerprint.analyze("https://example.com", resp)
    assert Enum.find(evidence, &(&1["name"] == "Cloudflare"))
  end

  test "returns error when fingerprints file is missing" do
    # Move the real database aside if it exists (e.g. downloaded in dev),
    # so no candidate path resolves to a file.
    default_path =
      Path.join(:code.priv_dir(:ravner) |> to_string(), "wappalyzer/technologies.json")

    backup_path = default_path <> ".test_bak"

    if File.exists?(default_path) do
      File.rename!(default_path, backup_path)
    end

    on_exit(fn ->
      if File.exists?(backup_path) do
        File.rename!(backup_path, default_path)
      end
    end)

    Application.put_env(
      :ravner,
      :wappalyzer_technologies_path,
      "/nonexistent/technologies.json"
    )

    resp = response([], "")

    assert {:error, :fingerprints_not_found} =
             TechFingerprint.analyze("https://example.com", resp)
  end

  test "fingerprint_url/2 returns error on connection failure" do
    assert {:error, _reason} =
             TechFingerprint.fingerprint_url("http://127.0.0.1:65530", receive_timeout: 500)
  end
end
