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
           } = Scans.parse_katana_output(output)
  end

  test "parse_webanalyze_output extracts technology evidence from jsonl" do
    output = """
    {"hostname":"https://example.com","matches":[{"app_name":"Phoenix","version":"1.8.0","cat_names":["Web Frameworks"]},{"app_name":"PostgreSQL","cat_names":["Databases"]}]}
    {"hostname":"https://example.com/about","matches":[{"app_name":"Phoenix","version":"1.8.0","cat_names":["Web Frameworks"]}]}
    """

    assert [
             %{
               "name" => "Phoenix",
               "version" => "1.8.0",
               "categories" => ["Web Frameworks"],
               "source" => "webanalyze",
               "url" => "https://example.com"
             },
             %{
               "name" => "PostgreSQL",
               "categories" => ["Databases"],
               "source" => "webanalyze",
               "url" => "https://example.com"
             }
           ] = Scans.parse_webanalyze_output(output)
  end
end
