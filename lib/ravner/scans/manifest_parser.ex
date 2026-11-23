defmodule Ravner.Scans.ManifestParser do
  @moduledoc """
  Functional parser for software dependency manifests and lockfiles.

  Extracts `{package_name, version, ecosystem}` tuples compatible with
  the Google OSV.dev schema and query batch endpoint.

  Supported lockfiles and ecosystems:
  - `mix.lock` → Hex
  - `package-lock.json` → npm
  - `yarn.lock` → npm
  - `pnpm-lock.yaml` → npm
  - `package.json` → npm (fallback pinned versions)
  - `requirements.txt` → PyPI
  - `Pipfile.lock` → PyPI
  - `poetry.lock` → PyPI
  - `composer.lock` → Packagist
  - `go.mod` → Go
  - `Cargo.lock` → crates.io
  - `Gemfile.lock` → RubyGems
  """

  @known_manifest_files [
    "mix.lock",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "package.json",
    "requirements.txt",
    "Pipfile.lock",
    "poetry.lock",
    "composer.lock",
    "go.mod",
    "Cargo.lock",
    "Gemfile.lock"
  ]

  @doc """
  Returns a list of supported manifest/lockfile filenames in precedence order.
  """
  @spec known_manifest_files() :: [String.t()]
  def known_manifest_files, do: @known_manifest_files

  @doc """
  Parses the content of a manifest file based on its filename.
  Returns a deduplicated list of `{package_name, version, ecosystem}`.
  """
  @spec parse(String.t(), binary()) :: [{String.t(), String.t(), String.t()}]
  def parse(filename, content) when is_binary(filename) and is_binary(content) do
    basename = Path.basename(filename)

    results =
      case basename do
        "mix.lock" ->
          parse_mix_lock(content)

        "package-lock.json" ->
          parse_package_lock_json(content)

        "yarn.lock" ->
          parse_yarn_lock(content)

        "pnpm-lock.yaml" ->
          parse_pnpm_lock(content)

        "package.json" ->
          parse_package_json(content)

        "requirements.txt" ->
          parse_requirements_txt(content)

        "Pipfile.lock" ->
          parse_pipfile_lock(content)

        "poetry.lock" ->
          parse_poetry_lock(content)

        "composer.lock" ->
          parse_composer_lock(content)

        "go.mod" ->
          parse_go_mod(content)

        "Cargo.lock" ->
          parse_cargo_lock(content)

        "Gemfile.lock" ->
          parse_gemfile_lock(content)

        _ ->
          []
      end

    results
    |> Enum.filter(fn {_pkg, ver, _eco} -> valid_version?(ver) end)
    |> Enum.uniq()
  end

  def parse(_, _), do: []

  # ─── 1. mix.lock (Hex) ───────────────────────────────────────────────────────

  defp parse_mix_lock(content) do
    # Matches: "pkg": {:hex, :pkg, "1.2.3", ...}
    Regex.scan(
      ~r/"([a-zA-Z0-9_\-\.]+)"\s*:\s*\{:hex,\s*:[a-zA-Z0-9_\-\.]+,\s*"([^"]+)"/,
      content,
      capture: :all_but_first
    )
    |> Enum.map(fn [pkg, ver] -> {pkg, clean_version(ver), "Hex"} end)
  end

  # ─── 2. package-lock.json (npm) ─────────────────────────────────────────────

  defp parse_package_lock_json(content) do
    case Jason.decode(content) do
      {:ok, %{"packages" => packages}} when is_map(packages) ->
        # npm v2 / v3 format
        Enum.flat_map(packages, fn
          {"", _} ->
            []

          {path, %{"version" => ver}} when is_binary(ver) ->
            pkg_name = extract_npm_package_name(path)
            if pkg_name, do: [{pkg_name, clean_version(ver), "npm"}], else: []

          _ ->
            []
        end)

      {:ok, %{"dependencies" => deps}} when is_map(deps) ->
        # npm v1 format
        extract_npm_v1_deps(deps)

      _ ->
        []
    end
  end

  defp extract_npm_package_name(path) do
    case String.split(path, "node_modules/") do
      [_, name] when name != "" -> name
      _ -> nil
    end
  end

  defp extract_npm_v1_deps(deps) do
    Enum.flat_map(deps, fn {name, info} ->
      current =
        case info do
          %{"version" => ver} when is_binary(ver) -> [{name, clean_version(ver), "npm"}]
          _ -> []
        end

      nested =
        case info do
          %{"dependencies" => nested_deps} when is_map(nested_deps) ->
            extract_npm_v1_deps(nested_deps)

          _ ->
            []
        end

      current ++ nested
    end)
  end

  # ─── 3. yarn.lock (npm) ─────────────────────────────────────────────────────

  defp parse_yarn_lock(content) do
    # Matches yarn v1 blocks:
    # "package@...":
    #   version "1.2.3"
    Regex.scan(
      ~r/(?:^|\n)(?:\"?(@?[a-zA-Z0-9_.\-\/]+)@[^:\n]+):\s*\n\s+version\s+["']?([^"'\n\r]+)["']?/,
      content,
      capture: :all_but_first
    )
    |> Enum.map(fn [pkg, ver] -> {pkg, clean_version(ver), "npm"} end)
  end

  # ─── 4. pnpm-lock.yaml (npm) ────────────────────────────────────────────────

  defp parse_pnpm_lock(content) do
    # Matches entries like:
    #   /axios@1.6.0: or axios@1.6.0: or /@sentry/browser@7.50.0:
    Regex.scan(
      ~r/^\s*(?:\/)?(@?[a-zA-Z0-9_.\-\/]+)@([0-9a-zA-Z_\.\-]+)(?:\(.*?\))?:/m,
      content,
      capture: :all_but_first
    )
    |> Enum.map(fn [pkg, ver] -> {pkg, clean_version(ver), "npm"} end)
  end

  # ─── 5. package.json (npm fallback) ─────────────────────────────────────────

  defp parse_package_json(content) do
    case Jason.decode(content) do
      {:ok, %{} = json} ->
        deps =
          Map.merge(
            Map.get(json, "dependencies", %{}),
            Map.get(json, "devDependencies", %{})
          )

        Enum.flat_map(deps, fn {pkg, raw_ver} ->
          if is_binary(raw_ver) do
            cleaned = clean_version(raw_ver)
            if valid_version?(cleaned), do: [{pkg, cleaned, "npm"}], else: []
          else
            []
          end
        end)

      _ ->
        []
    end
  end

  # ─── 6. requirements.txt (PyPI) ─────────────────────────────────────────────

  defp parse_requirements_txt(content) do
    Regex.scan(
      ~r/^\s*([a-zA-Z0-9_\-\.]+)\s*(?:==|>=|<=|~=)\s*([0-9a-zA-Z_\.\-]+)/m,
      content,
      capture: :all_but_first
    )
    |> Enum.map(fn [pkg, ver] -> {pkg, clean_version(ver), "PyPI"} end)
  end

  # ─── 7. Pipfile.lock (PyPI) ─────────────────────────────────────────────────

  defp parse_pipfile_lock(content) do
    case Jason.decode(content) do
      {:ok, %{} = json} ->
        pkgs = Map.merge(Map.get(json, "default", %{}), Map.get(json, "develop", %{}))

        Enum.flat_map(pkgs, fn {pkg, info} ->
          case info do
            %{"version" => ver} when is_binary(ver) ->
              cleaned = clean_version(ver)
              if valid_version?(cleaned), do: [{pkg, cleaned, "PyPI"}], else: []

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  # ─── 8. poetry.lock (PyPI) ──────────────────────────────────────────────────

  defp parse_poetry_lock(content) do
    Regex.scan(
      ~r/\[\[package\]\]\s*\n(?:[^\n]*\n)*?name\s*=\s*"([^"]+)"\s*\n(?:[^\n]*\n)*?version\s*=\s*"([^"]+)"/,
      content,
      capture: :all_but_first
    )
    |> Enum.map(fn [pkg, ver] -> {pkg, clean_version(ver), "PyPI"} end)
  end

  # ─── 9. composer.lock (Packagist) ───────────────────────────────────────────

  defp parse_composer_lock(content) do
    case Jason.decode(content) do
      {:ok, %{} = json} ->
        pkgs = Map.get(json, "packages", []) ++ Map.get(json, "packages-dev", [])

        Enum.flat_map(pkgs, fn
          %{"name" => name, "version" => ver} when is_binary(name) and is_binary(ver) ->
            cleaned = clean_version(ver)
            if valid_version?(cleaned), do: [{name, cleaned, "Packagist"}], else: []

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  # ─── 10. go.mod (Go) ────────────────────────────────────────────────────────

  defp parse_go_mod(content) do
    Regex.scan(
      ~r/^\s*([a-zA-Z0-9_\-\.\/]+)\s+v([0-9a-zA-Z_\.\-]+)/m,
      content,
      capture: :all_but_first
    )
    |> Enum.map(fn [pkg, ver] -> {pkg, clean_version(ver), "Go"} end)
  end

  # ─── 11. Cargo.lock (crates.io) ─────────────────────────────────────────────

  defp parse_cargo_lock(content) do
    Regex.scan(
      ~r/\[\[package\]\]\s*\n(?:[^\n]*\n)*?name\s*=\s*"([^"]+)"\s*\n(?:[^\n]*\n)*?version\s*=\s*"([^"]+)"/,
      content,
      capture: :all_but_first
    )
    |> Enum.map(fn [pkg, ver] -> {pkg, clean_version(ver), "crates.io"} end)
  end

  # ─── 12. Gemfile.lock (RubyGems) ────────────────────────────────────────────

  defp parse_gemfile_lock(content) do
    Regex.scan(
      ~r/^\s{4}([a-zA-Z0-9_\-\.]+)\s+\(([0-9a-zA-Z_\.\-]+)\)/m,
      content,
      capture: :all_but_first
    )
    |> Enum.map(fn [pkg, ver] -> {pkg, clean_version(ver), "RubyGems"} end)
  end

  # ─── Helpers ────────────────────────────────────────────────────────────────

  @doc """
  Strips version prefixes (like `v`, `==`, `^`, `~`, `>=`) and extracts numeric version.
  """
  @spec clean_version(String.t()) :: String.t()
  def clean_version(version) when is_binary(version) do
    version
    |> String.trim()
    |> String.replace_prefix("v", "")
    |> String.replace_prefix("==", "")
    |> String.replace_prefix("^", "")
    |> String.replace_prefix("~", "")
    |> String.replace_prefix(">=", "")
    |> String.replace_prefix("<=", "")
    |> String.trim()
  end

  def clean_version(_), do: ""

  @doc """
  Returns true if the version string is valid, non-empty, and starts with a digit.
  """
  @spec valid_version?(term()) :: boolean()
  def valid_version?(version) when is_binary(version) do
    trimmed = String.trim(version)
    trimmed != "" and Regex.match?(~r/^\d+(\.\d+)*/, trimmed)
  end

  def valid_version?(_), do: false
end
