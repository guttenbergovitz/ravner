defmodule Ravner.Scans.ManifestParserTest do
  use ExUnit.Case, async: true

  alias Ravner.Scans.ManifestParser

  describe "known_manifest_files/0" do
    test "returns list of supported manifest filenames" do
      files = ManifestParser.known_manifest_files()
      assert "mix.lock" in files
      assert "package-lock.json" in files
      assert "requirements.txt" in files
      assert "go.mod" in files
      assert "Cargo.lock" in files
    end
  end

  describe "parse/2 mix.lock" do
    test "extracts Hex packages and versions" do
      content = """
      %{
        "bandit": {:hex, :bandit, "1.5.7", "hash", [:mix], [], "hexpm", "hash"},
        "decimal": {:hex, :decimal, "2.2.0", "hash", [:mix], [], "hexpm", "hash"},
        "phoenix": {:hex, :phoenix, "1.7.14", "hash", [:mix], [], "hexpm", "hash"}
      }
      """

      results = ManifestParser.parse("mix.lock", content)

      assert {"bandit", "1.5.7", "Hex"} in results
      assert {"decimal", "2.2.0", "Hex"} in results
      assert {"phoenix", "1.7.14", "Hex"} in results
    end
  end

  describe "parse/2 package-lock.json" do
    test "extracts npm packages from v2/v3 packages map" do
      content = """
      {
        "name": "my-app",
        "version": "1.0.0",
        "lockfileVersion": 3,
        "packages": {
          "": { "name": "my-app", "version": "1.0.0" },
          "node_modules/axios": { "version": "1.6.2" },
          "node_modules/@sentry/browser": { "version": "7.80.0" }
        }
      }
      """

      results = ManifestParser.parse("package-lock.json", content)

      assert {"axios", "1.6.2", "npm"} in results
      assert {"@sentry/browser", "7.80.0", "npm"} in results
      refute {"my-app", "1.0.0", "npm"} in results
    end

    test "extracts npm packages from v1 dependencies map" do
      content = """
      {
        "name": "my-app",
        "version": "1.0.0",
        "lockfileVersion": 1,
        "dependencies": {
          "lodash": { "version": "4.17.21" },
          "express": {
            "version": "4.18.2",
            "dependencies": {
              "qs": { "version": "6.11.0" }
            }
          }
        }
      }
      """

      results = ManifestParser.parse("package-lock.json", content)

      assert {"lodash", "4.17.21", "npm"} in results
      assert {"express", "4.18.2", "npm"} in results
      assert {"qs", "6.11.0", "npm"} in results
    end
  end

  describe "parse/2 yarn.lock" do
    test "extracts packages from yarn v1 format" do
      content = """
      "axios@^1.6.0":
        version "1.6.2"
        resolved "https://registry.yarnpkg.com/axios/-/axios-1.6.2.tgz"

      "@types/node@*":
        version "20.10.0"
        resolved "https://registry.yarnpkg.com/@types/node/-/node-20.10.0.tgz"
      """

      results = ManifestParser.parse("yarn.lock", content)

      assert {"axios", "1.6.2", "npm"} in results
      assert {"@types/node", "20.10.0", "npm"} in results
    end
  end

  describe "parse/2 package.json" do
    test "extracts dependencies with stripped prefixes" do
      content = """
      {
        "dependencies": {
          "react": "^18.2.0",
          "next": "~14.0.1"
        },
        "devDependencies": {
          "typescript": "5.3.3"
        }
      }
      """

      results = ManifestParser.parse("package.json", content)

      assert {"react", "18.2.0", "npm"} in results
      assert {"next", "14.0.1", "npm"} in results
      assert {"typescript", "5.3.3", "npm"} in results
    end
  end

  describe "parse/2 requirements.txt" do
    test "extracts PyPI packages with version constraints" do
      content = """
      django==4.2.7
      requests>=2.31.0
      celery~=5.3.4
      # comments should be ignored
      flask==3.0.0
      """

      results = ManifestParser.parse("requirements.txt", content)

      assert {"django", "4.2.7", "PyPI"} in results
      assert {"requests", "2.31.0", "PyPI"} in results
      assert {"celery", "5.3.4", "PyPI"} in results
      assert {"flask", "3.0.0", "PyPI"} in results
    end
  end

  describe "parse/2 composer.lock" do
    test "extracts Packagist packages" do
      content = """
      {
        "packages": [
          { "name": "laravel/framework", "version": "v10.33.0" },
          { "name": "monolog/monolog", "version": "3.5.0" }
        ],
        "packages-dev": [
          { "name": "phpunit/phpunit", "version": "v10.4.2" }
        ]
      }
      """

      results = ManifestParser.parse("composer.lock", content)

      assert {"laravel/framework", "10.33.0", "Packagist"} in results
      assert {"monolog/monolog", "3.5.0", "Packagist"} in results
      assert {"phpunit/phpunit", "10.4.2", "Packagist"} in results
    end
  end

  describe "parse/2 go.mod" do
    test "extracts Go module dependencies" do
      content = """
      module example.com/my/app

      go 1.21

      require (
        github.com/gin-gonic/gin v1.9.1
        golang.org/x/crypto v0.16.0
      )
      """

      results = ManifestParser.parse("go.mod", content)

      assert {"github.com/gin-gonic/gin", "1.9.1", "Go"} in results
      assert {"golang.org/x/crypto", "0.16.0", "Go"} in results
    end
  end

  describe "parse/2 Cargo.lock" do
    test "extracts Rust crates" do
      content = """
      version = 3

      [[package]]
      name = "tokio"
      version = "1.33.0"
      source = "registry+https://github.com/rust-lang/crates.io-index"

      [[package]]
      name = "serde"
      version = "1.0.189"
      """

      results = ManifestParser.parse("Cargo.lock", content)

      assert {"tokio", "1.33.0", "crates.io"} in results
      assert {"serde", "1.0.189", "crates.io"} in results
    end
  end
end
