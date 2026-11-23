defmodule Ravner.Integrations.VCS.TechDetector do
  @moduledoc """
  Unified technology stack and framework detection for repository files and manifests.
  Shared across Bitbucket, GitHub, and GitLab adapters.
  """

  @doc """
  Detects technologies from an enumerable of filenames and optional package.json body/map.
  """
  @spec detect_technologies(Enumerable.t(), map() | String.t() | nil) :: [String.t()]
  def detect_technologies(files, package_json \\ nil) do
    file_set = if is_struct(files, MapSet), do: files, else: MapSet.new(files)
    file_techs = detect_from_files(file_set)

    package_techs =
      if package_json do
        parse_package_json_dependencies(package_json)
      else
        []
      end

    Enum.uniq(file_techs ++ package_techs)
  end

  @doc """
  Parses package.json dependencies (production & dev) to detect frontend and backend frameworks.
  """
  @spec parse_package_json_dependencies(map() | String.t()) :: [String.t()]
  def parse_package_json_dependencies(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} -> parse_package_json_dependencies(json)
      _ -> []
    end
  end

  def parse_package_json_dependencies(%{} = json) do
    deps =
      Map.merge(
        Map.get(json, "dependencies", %{}),
        Map.get(json, "devDependencies", %{})
      )

    tech_mappings = [
      {"react", "React"},
      {"vue", "Vue"},
      {"next", "Next.js"},
      {"nuxt", "Nuxt"},
      {"@angular/core", "Angular"},
      {"svelte", "Svelte"},
      {"tailwindcss", "Tailwind CSS"},
      {"typescript", "TypeScript"},
      {"express", "Express"},
      {"nest", "NestJS"},
      {"vite", "Vite"}
    ]

    Enum.reduce(tech_mappings, [], fn {pkg, label}, acc ->
      if Map.has_key?(deps, pkg) do
        [label | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  def parse_package_json_dependencies(_), do: []

  @doc """
  Detects primary language and frameworks based on manifest and configuration file presence.
  """
  @spec detect_from_files(MapSet.t()) :: [String.t()]
  def detect_from_files(%MapSet{} = files) do
    mappings = [
      {"mix.exs", ["Elixir", "Phoenix"]},
      {"package.json", ["Node.js"]},
      {"tsconfig.json", ["TypeScript"]},
      {"pom.xml", ["Java", "Maven"]},
      {"build.gradle", ["Java", "Gradle"]},
      {"requirements.txt", ["Python"]},
      {"pyproject.toml", ["Python"]},
      {"Pipfile", ["Python"]},
      {"composer.json", ["PHP"]},
      {"Cargo.toml", ["Rust"]},
      {"go.mod", ["Go"]},
      {"Dockerfile", ["Docker"]},
      {"docker-compose.yml", ["Docker Compose"]},
      {"bitbucket-pipelines.yml", ["Bitbucket Pipelines"]},
      {".github/workflows", ["GitHub Actions"]},
      {".gitlab-ci.yml", ["GitLab CI"]}
    ]

    Enum.reduce(mappings, [], fn {file, tags}, acc ->
      if MapSet.member?(files, file) do
        acc ++ tags
      else
        acc
      end
    end)
    |> Enum.uniq()
  end
end
