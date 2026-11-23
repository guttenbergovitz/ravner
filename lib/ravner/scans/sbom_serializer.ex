defmodule Ravner.Scans.SbomSerializer do
  @moduledoc """
  Serializes project and repository dependencies into spec-compliant
  CycloneDX 1.5 JSON Software Bill of Materials (SBOM) documents.

  Supports Package URL (purl) generation across all 12 ecosystems supported
  by `Ravner.Scans.ManifestParser`:
  - Hex (Elixir/Erlang)
  - npm (JavaScript/TypeScript, including scoped packages)
  - PyPI (Python)
  - Packagist / Composer (PHP)
  - Go / Golang
  - crates.io / Cargo (Rust)
  - RubyGems (Ruby)
  - Maven / Nuget / Generic fallbacks
  """

  alias Ravner.Inventory
  alias Ravner.Inventory.Project
  alias Ravner.Inventory.ProjectRepository
  alias Ravner.Integrations.VCS
  alias Ravner.Repo
  alias Ravner.Scans.ProjectRepositoryVulnerability
  alias Ravner.Scans.RepoScanner
  alias Ravner.SecurityScans

  @cyclonedx_schema "http://cyclonedx.org/schema/bom-1.5.schema.json"
  @cyclonedx_spec_version "1.5"
  @tool_vendor "Ravner"
  @tool_name "Ravner ASM"
  @tool_version "0.11.0"

  @type dep_input ::
          {String.t(), String.t(), String.t()}
          | {String.t(), String.t(), String.t(), String.t() | nil}
          | map()
          | ProjectRepositoryVulnerability.t()

  @doc """
  Constructs a standard Package URL (purl) conforming to the purl specification.
  """
  @spec purl(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def purl(ecosystem, name, version \\ nil)

  def purl(nil, name, version), do: purl("generic", name, version)
  def purl(_eco, nil, _version), do: "pkg:generic/unknown"

  def purl(ecosystem, name, version) when is_binary(ecosystem) and is_binary(name) do
    type =
      case String.downcase(String.trim(ecosystem)) do
        "hex" -> "hex"
        "npm" -> "npm"
        "pypi" -> "pypi"
        "packagist" -> "composer"
        "composer" -> "composer"
        "go" -> "golang"
        "golang" -> "golang"
        "crates.io" -> "cargo"
        "cargo" -> "cargo"
        "rubygems" -> "gem"
        "gem" -> "gem"
        "maven" -> "maven"
        "nuget" -> "nuget"
        other -> other
      end

    formatted_name =
      case type do
        "npm" ->
          trimmed = String.trim(name)

          if String.starts_with?(trimmed, "@") do
            "%40" <> String.slice(trimmed, 1..-1//1)
          else
            trimmed
          end

        "pypi" ->
          name |> String.trim() |> String.downcase() |> String.replace("_", "-")

        _ ->
          String.trim(name)
      end

    v = if is_binary(version) and String.trim(version) != "", do: String.trim(version), else: nil

    if v do
      "pkg:#{type}/#{formatted_name}@#{v}"
    else
      "pkg:#{type}/#{formatted_name}"
    end
  end

  @doc """
  Generates a CycloneDX 1.5 SBOM document map from given component metadata,
  dependencies, and options.

  ## Options
  - `:vulnerabilities` - list of vulnerabilities (maps or `ProjectRepositoryVulnerability` structs)
  - `:serial_number` - explicit serial number URN (defaults to generated UUID)
  - `:timestamp` - DateTime for the BOM metadata timestamp
  """
  @spec generate(map(), [dep_input()], keyword()) :: {:ok, map()}
  def generate(component_meta, dependencies, opts \\ []) do
    timestamp =
      Keyword.get(opts, :timestamp) ||
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    serial_number =
      Keyword.get(opts, :serial_number) ||
        "urn:uuid:#{Ecto.UUID.generate()}"

    comp_name = component_meta[:name] || component_meta["name"] || "application"
    comp_version = component_meta[:version] || component_meta["version"] || "1.0.0"

    root_component = %{
      "type" => "application",
      "name" => to_string(comp_name),
      "version" => to_string(comp_version)
    }

    root_component =
      case component_meta[:description] || component_meta["description"] do
        desc when is_binary(desc) and desc != "" -> Map.put(root_component, "description", desc)
        _ -> root_component
      end

    components = build_components(dependencies)

    vulnerabilities =
      opts
      |> Keyword.get(:vulnerabilities, [])
      |> build_vulnerabilities()

    bom = %{
      "$schema" => @cyclonedx_schema,
      "bomFormat" => "CycloneDX",
      "specVersion" => @cyclonedx_spec_version,
      "serialNumber" => serial_number,
      "version" => 1,
      "metadata" => %{
        "timestamp" => timestamp,
        "tools" => [
          %{
            "vendor" => @tool_vendor,
            "name" => @tool_name,
            "version" => @tool_version
          }
        ],
        "component" => root_component
      },
      "components" => components
    }

    bom =
      if vulnerabilities != [] do
        Map.put(bom, "vulnerabilities", vulnerabilities)
      else
        bom
      end

    {:ok, bom}
  end

  @doc """
  Generates a CycloneDX 1.5 SBOM for a `ProjectRepository`.
  Fetches dependencies via `RepoScanner.fetch_manifest_dependencies/1`
  and loads vulnerabilities from `SecurityScans.list_repository_vulnerabilities/1`.
  """
  @spec generate_for_repository(ProjectRepository.t() | integer(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def generate_for_repository(repo_or_id, opts \\ [])

  def generate_for_repository(repo_id, opts) when is_integer(repo_id) do
    case Repo.get(ProjectRepository, repo_id) do
      nil -> {:error, "Repository #{repo_id} not found"}
      repo -> generate_for_repository(repo, opts)
    end
  end

  def generate_for_repository(%ProjectRepository{} = repo, opts) do
    vulns =
      Keyword.get(opts, :vulnerabilities) ||
        SecurityScans.list_repository_vulnerabilities(repo.id)

    deps_result =
      case Keyword.fetch(opts, :dependencies) do
        {:ok, deps} ->
          {:ok, deps}

        :error ->
          case RepoScanner.fetch_manifest_dependencies(repo) do
            {:ok, deps} ->
              {:ok, deps}

            {:error, reason} ->
              if vulns != [] do
                vuln_deps =
                  Enum.map(vulns, fn v ->
                    {v.package_name, v.package_version, v.ecosystem, v.manifest_file}
                  end)

                {:ok, vuln_deps}
              else
                {:error, reason}
              end
          end
      end

    case deps_result do
      {:ok, deps} ->
        # Merge any vulnerability components that might not be in the parsed lockfile
        vuln_deps =
          Enum.map(vulns, fn v ->
            {v.package_name, v.package_version, v.ecosystem, v.manifest_file}
          end)

        all_deps = deps ++ vuln_deps

        slug = repo.external_id || VCS.extract_slug_from_url(repo.url) || repo.url
        version = repo.last_commit_hash || repo.default_branch || "main"

        meta = %{
          name: slug,
          version: version,
          url: repo.url,
          kind: repo.kind
        }

        generate(meta, all_deps, Keyword.put(opts, :vulnerabilities, vulns))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates an aggregated CycloneDX 1.5 SBOM for an entire `Project`,
  combining components and vulnerabilities across all its attached repositories.
  """
  @spec generate_for_project(Project.t() | integer() | String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def generate_for_project(project_or_id, opts \\ [])

  def generate_for_project(project_id, opts)
      when is_integer(project_id) or is_binary(project_id) do
    case Repo.get(Project, project_id) do
      nil -> {:error, "Project #{project_id} not found"}
      project -> generate_for_project(project, opts)
    end
  end

  def generate_for_project(%Project{} = project, opts) do
    repositories =
      Keyword.get(opts, :repositories) ||
        Inventory.list_project_repositories(project.id)

    vulns =
      Keyword.get(opts, :vulnerabilities) ||
        Enum.flat_map(repositories, fn repo ->
          SecurityScans.list_repository_vulnerabilities(repo.id)
        end)

    all_deps =
      case Keyword.fetch(opts, :dependencies) do
        {:ok, deps} ->
          deps

        :error ->
          fetched =
            Enum.flat_map(repositories, fn repo ->
              case RepoScanner.fetch_manifest_dependencies(repo) do
                {:ok, deps} -> deps
                _ -> []
              end
            end)

          vuln_deps =
            Enum.map(vulns, fn v ->
              {v.package_name, v.package_version, v.ecosystem, v.manifest_file}
            end)

          fetched ++ vuln_deps
      end

    meta = %{
      name: project.slug || project.name,
      version: "1.0.0",
      description: project.description
    }

    generate(meta, all_deps, Keyword.put(opts, :vulnerabilities, vulns))
  end

  @doc """
  Encodes a CycloneDX SBOM map to a JSON string.
  """
  @spec to_json(map(), keyword()) :: {:ok, String.t()} | {:error, Jason.EncodeError.t()}
  def to_json(bom_map, opts \\ [pretty: true]) do
    Jason.encode(bom_map, opts)
  end

  @doc """
  Encodes a CycloneDX SBOM map to a JSON string, raising on error.
  """
  @spec to_json!(map(), keyword()) :: String.t()
  def to_json!(bom_map, opts \\ [pretty: true]) do
    Jason.encode!(bom_map, opts)
  end

  # ─── Internal Helpers ────────────────────────────────────────────────────────

  defp build_components(dependencies) do
    dependencies
    |> Enum.map(&normalize_dependency/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn dep -> dep.purl end)
    |> Enum.sort_by(fn dep -> dep.name end)
    |> Enum.map(fn dep ->
      comp = %{
        "type" => "library",
        "bom-ref" => dep.purl,
        "name" => dep.name,
        "version" => dep.version,
        "purl" => dep.purl,
        "scope" => "required"
      }

      if dep.manifest_file && dep.manifest_file != "" do
        Map.put(comp, "properties", [
          %{"name" => "ravner:manifest_file", "value" => dep.manifest_file}
        ])
      else
        comp
      end
    end)
  end

  defp normalize_dependency({name, version, ecosystem, manifest_file}) do
    build_normalized_dep(name, version, ecosystem, manifest_file)
  end

  defp normalize_dependency({name, version, ecosystem}) do
    build_normalized_dep(name, version, ecosystem, nil)
  end

  defp normalize_dependency(%ProjectRepositoryVulnerability{} = v) do
    build_normalized_dep(v.package_name, v.package_version, v.ecosystem, v.manifest_file)
  end

  defp normalize_dependency(map) when is_map(map) do
    name = map[:name] || map["name"] || map[:package_name] || map["package_name"]
    version = map[:version] || map["version"] || map[:package_version] || map["package_version"]
    ecosystem = map[:ecosystem] || map["ecosystem"]
    manifest_file = map[:manifest_file] || map["manifest_file"]

    if name && ecosystem do
      build_normalized_dep(name, version, ecosystem, manifest_file)
    else
      nil
    end
  end

  defp normalize_dependency(_), do: nil

  defp build_normalized_dep(name, version, ecosystem, manifest_file) do
    name_str = to_string(name) |> String.trim()
    ver_str = if version, do: to_string(version) |> String.trim(), else: ""
    eco_str = to_string(ecosystem) |> String.trim()
    manifest_str = if manifest_file, do: to_string(manifest_file) |> String.trim(), else: nil

    %{
      name: name_str,
      version: ver_str,
      ecosystem: eco_str,
      manifest_file: manifest_str,
      purl: purl(eco_str, name_str, ver_str)
    }
  end

  defp build_vulnerabilities(vulnerabilities) do
    vulnerabilities
    |> Enum.map(&normalize_vulnerability/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(fn vuln -> vuln.id end)
    |> Enum.map(fn {id, vulns_for_id} ->
      first = hd(vulns_for_id)
      affects = Enum.map(vulns_for_id, fn v -> %{"ref" => v.purl} end) |> Enum.uniq()

      vuln_map = %{
        "bom-ref" => "#{id}-#{first.purl}",
        "id" => id,
        "source" => %{
          "name" => if(String.starts_with?(id, "CVE-"), do: "NVD", else: "OSV")
        },
        "ratings" => [
          %{
            "severity" => first.severity,
            "method" => "other"
          }
        ],
        "description" => first.description,
        "affects" => affects
      }

      fixed = Enum.find_value(vulns_for_id, fn v -> v.fixed_version end)

      if fixed && fixed != "" do
        Map.put(vuln_map, "recommendation", "Upgrade #{first.package_name} to #{fixed}")
      else
        vuln_map
      end
    end)
    |> Enum.sort_by(fn vuln ->
      severity = get_in(vuln, ["ratings", Access.at(0), "severity"]) || "unknown"
      {severity_rank(severity), vuln["id"]}
    end)
  end

  defp normalize_vulnerability(%ProjectRepositoryVulnerability{} = v) do
    id = v.cve_id || v.osv_id || "VULN-UNKNOWN"
    sev = normalize_severity(v.severity)
    purl = purl(v.ecosystem, v.package_name, v.package_version)

    %{
      id: id,
      package_name: v.package_name,
      package_version: v.package_version,
      ecosystem: v.ecosystem,
      severity: sev,
      description: v.summary || "",
      fixed_version: v.fixed_version,
      purl: purl
    }
  end

  defp normalize_vulnerability(map) when is_map(map) do
    id =
      map[:cve_id] || map["cve_id"] ||
        map[:cve] || map["cve"] ||
        map[:osv_id] || map["osv_id"] ||
        map[:id] || map["id"] ||
        "VULN-UNKNOWN"

    pkg = map[:package_name] || map["package_name"] || map[:tech] || map["tech"] || ""
    ver = map[:package_version] || map["package_version"] || map[:version] || map["version"] || ""
    eco = map[:ecosystem] || map["ecosystem"] || "generic"
    sev = normalize_severity(map[:severity] || map["severity"])
    desc = map[:summary] || map["summary"] || map[:description] || map["description"] || ""
    fixed = map[:fixed_version] || map["fixed_version"]

    purl = purl(to_string(eco), to_string(pkg), to_string(ver))

    %{
      id: to_string(id),
      package_name: to_string(pkg),
      package_version: to_string(ver),
      ecosystem: to_string(eco),
      severity: sev,
      description: to_string(desc),
      fixed_version: if(fixed, do: to_string(fixed), else: nil),
      purl: purl
    }
  end

  defp normalize_vulnerability(_), do: nil

  defp normalize_severity(sev) when is_binary(sev) do
    lower = String.downcase(String.trim(sev))
    if lower in ~w(none low medium high critical unknown), do: lower, else: "unknown"
  end

  defp normalize_severity(_), do: "unknown"

  defp severity_rank("critical"), do: 0
  defp severity_rank("high"), do: 1
  defp severity_rank("medium"), do: 2
  defp severity_rank("low"), do: 3
  defp severity_rank(_), do: 4
end
