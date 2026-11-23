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

  test "parse_katana_output extracts crawled urls and javascript assets from jsonl" do
    output = """
    {"url":"https://example.com/","source":"root"}
    {"url":"https://example.com/assets/app.js","source":"script"}
    {"request":{"endpoint":"https://example.com/contact"},"tag":"a"}
    https://example.com/plain
    not-json
    """

    assert %{
             urls: [
               %{"url" => "https://example.com/", "source" => "root"},
               %{"url" => "https://example.com/assets/app.js", "source" => "script"},
               %{"url" => "https://example.com/contact", "source" => "a"},
               %{"url" => "https://example.com/plain", "source" => "katana"}
             ],
             js_assets: ["https://example.com/assets/app.js"],
             forms: []
           } = Scans.Http.parse_katana_output(output)
  end

  describe "external_redirect?/2" do
    test "returns false for nil final_url" do
      refute Scans.external_redirect?("example.com", nil)
    end

    test "returns false for same domain" do
      refute Scans.external_redirect?("example.com", "https://example.com/page")
    end

    test "returns false for www variant" do
      refute Scans.external_redirect?("example.com", "https://www.example.com/page")
    end

    test "returns false for subdomain of same root" do
      refute Scans.external_redirect?("example.com", "https://blog.example.com/page")
    end

    test "returns true for different apex domain" do
      assert Scans.external_redirect?("old-brand.com", "https://new-brand.com/page")
    end

    test "returns true for different apex with subdomain source" do
      assert Scans.external_redirect?("shop.old-brand.com", "https://new-brand.com/")
    end

    test "handles two-part TLDs correctly" do
      refute Scans.external_redirect?("example.co.uk", "https://www.example.co.uk/page")
      assert Scans.external_redirect?("example.co.uk", "https://other.co.uk/page")
    end

    test "detects registrar parking and external landing redirects" do
      assert Scans.external_redirect?(
               "farmchamps.com",
               "https://forsale.godaddy.com/forsale/farmchamps.com"
             )

      assert Scans.external_redirect?(
               "probe.acme.example",
               "https://docs.google.com/forms/d/e/123/viewform"
             )
    end
  end
end
