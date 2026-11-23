defmodule Ravner.Integrations.VCS.GitHub do
  @moduledoc """
  GitHub REST API v3 adapter.
  Implements `Ravner.Integrations.VCS.Adapter` using `:req`.
  Supports GitHub Personal Access Tokens (Classic and Fine-grained) via HTTP Bearer auth.
  """

  @behaviour Ravner.Integrations.VCS.Adapter

  alias Ravner.Integrations.VCS.Commit
  alias Ravner.Integrations.VCS.Repository
  alias Ravner.Integrations.VCS.TechDetector

  @base_url "https://api.github.com"

  @impl true
  def test_connection(credentials) do
    workspace = get_workspace(credentials)
    client = build_client(credentials)

    cond do
      is_binary(workspace) and workspace != "" ->
        # Try org endpoint first, fallback to user endpoint if 404
        case Req.get(client, url: "/orgs/#{workspace}") do
          {:ok, %Req.Response{status: 200}} ->
            :ok

          {:ok, %Req.Response{status: 404}} ->
            case Req.get(client, url: "/users/#{workspace}") do
              {:ok, %Req.Response{status: 200}} ->
                :ok

              {:ok, %Req.Response{status: 404}} ->
                {:error, "GitHub organization or user '#{workspace}' not found"}

              {:ok, %Req.Response{status: status, body: body}} ->
                msg = extract_error_message(body) || "GitHub API error (HTTP #{status})"
                {:error, msg}

              {:error, reason} ->
                {:error, "Failed to connect to GitHub: #{inspect(reason)}"}
            end

          {:ok, %Req.Response{status: 401}} ->
            {:error, "Authentication failed: invalid GitHub Personal Access Token"}

          {:ok, %Req.Response{status: 403}} ->
            {:error, "Access denied: check repository read permissions on your GitHub token"}

          {:ok, %Req.Response{status: status, body: body}} ->
            msg = extract_error_message(body) || "GitHub API error (HTTP #{status})"
            {:error, msg}

          {:error, reason} ->
            {:error, "Failed to connect to GitHub: #{inspect(reason)}"}
        end

      true ->
        # No workspace specified, test token against authenticated user endpoint
        case Req.get(client, url: "/user") do
          {:ok, %Req.Response{status: 200}} ->
            :ok

          {:ok, %Req.Response{status: 401}} ->
            {:error, "Authentication failed: invalid GitHub Personal Access Token"}

          {:ok, %Req.Response{status: status, body: body}} ->
            msg = extract_error_message(body) || "GitHub API error (HTTP #{status})"
            {:error, msg}

          {:error, reason} ->
            {:error, "Failed to connect to GitHub: #{inspect(reason)}"}
        end
    end
  end

  @impl true
  def list_repositories(credentials, opts \\ []) do
    workspace = get_workspace(credentials)
    client = build_client(credentials)
    limit = Keyword.get(opts, :limit, 50)
    search = Keyword.get(opts, :search)

    url =
      cond do
        is_binary(workspace) and workspace != "" ->
          "/orgs/#{workspace}/repos"

        true ->
          "/user/repos"
      end

    params = [
      per_page: min(limit, 100),
      sort: "updated",
      direction: "desc"
    ]

    case Req.get(client, url: url, params: params) do
      {:ok, %Req.Response{status: 200, body: items}} when is_list(items) ->
        repos =
          items
          |> Enum.map(&map_repository/1)
          |> maybe_filter_search(search)

        {:ok, repos}

      {:ok, %Req.Response{status: 404}} when is_binary(workspace) and workspace != "" ->
        # Fallback to users/{user}/repos if org returned 404
        user_url = "/users/#{workspace}/repos"

        case Req.get(client, url: user_url, params: params) do
          {:ok, %Req.Response{status: 200, body: items}} when is_list(items) ->
            repos =
              items
              |> Enum.map(&map_repository/1)
              |> maybe_filter_search(search)

            {:ok, repos}

          {:ok, %Req.Response{status: status, body: body}} ->
            msg = extract_error_message(body) || "Failed to list repositories (HTTP #{status})"
            {:error, msg}

          {:error, reason} ->
            {:error, "GitHub connection error: #{inspect(reason)}"}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        msg = extract_error_message(body) || "Failed to list repositories (HTTP #{status})"
        {:error, msg}

      {:error, reason} ->
        {:error, "GitHub connection error: #{inspect(reason)}"}
    end
  end

  @impl true
  def get_repository(credentials, repo_slug) do
    workspace = get_workspace(credentials)
    client = build_client(credentials)
    repo_path = resolve_repo_path(workspace, repo_slug)

    case Req.get(client, url: "/repos/#{repo_path}") do
      {:ok, %Req.Response{status: 200, body: item}} ->
        {:ok, map_repository(item)}

      {:ok, %Req.Response{status: 404}} ->
        {:error, "Repository '#{repo_path}' not found on GitHub"}

      {:ok, %Req.Response{status: status, body: body}} ->
        msg = extract_error_message(body) || "Failed to fetch repository (HTTP #{status})"
        {:error, msg}

      {:error, reason} ->
        {:error, "GitHub connection error: #{inspect(reason)}"}
    end
  end

  @impl true
  def list_commits(credentials, repo_slug, opts \\ []) do
    workspace = get_workspace(credentials)
    client = build_client(credentials)
    repo_path = resolve_repo_path(workspace, repo_slug)
    limit = Keyword.get(opts, :limit, 10)

    params = [per_page: min(limit, 100)]

    case Req.get(client, url: "/repos/#{repo_path}/commits", params: params) do
      {:ok, %Req.Response{status: 200, body: items}} when is_list(items) ->
        {:ok, Enum.map(items, &map_commit/1)}

      {:ok, %Req.Response{status: 404}} ->
        {:error, "Repository '#{repo_path}' not found on GitHub"}

      {:ok, %Req.Response{status: status, body: body}} ->
        msg = extract_error_message(body) || "Failed to fetch commits (HTTP #{status})"
        {:error, msg}

      {:error, reason} ->
        {:error, "GitHub connection error: #{inspect(reason)}"}
    end
  end

  @impl true
  def detect_tech_stack(credentials, repo_slug, default_branch \\ "main") do
    workspace = get_workspace(credentials)
    client = build_client(credentials)
    repo_path = resolve_repo_path(workspace, repo_slug)

    # 1. Fetch language statistics from GitHub API
    detected_from_api =
      case Req.get(client, url: "/repos/#{repo_path}/languages") do
        {:ok, %Req.Response{status: 200, body: %{} = langs}} ->
          Map.keys(langs)

        _ ->
          []
      end

    # 2. Inspect root manifest files
    manifest_files = [
      "mix.exs",
      "package.json",
      "tsconfig.json",
      "pom.xml",
      "build.gradle",
      "requirements.txt",
      "pyproject.toml",
      "Pipfile",
      "composer.json",
      "Cargo.toml",
      "go.mod",
      "Dockerfile",
      "docker-compose.yml"
    ]

    discovered_files =
      case Req.get(client, url: "/repos/#{repo_path}/git/trees/#{default_branch}") do
        {:ok, %Req.Response{status: 200, body: %{"tree" => tree}}} when is_list(tree) ->
          tree
          |> Enum.map(& &1["path"])
          |> Enum.filter(&(&1 in manifest_files))
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    # 3. If package.json is present, inspect framework dependencies
    package_json =
      if MapSet.member?(discovered_files, "package.json") do
        case fetch_file(credentials, repo_slug, "package.json", default_branch) do
          {:ok, content} -> content
          _ -> nil
        end
      else
        nil
      end

    file_techs = TechDetector.detect_technologies(discovered_files, package_json)

    all_techs = Enum.uniq(detected_from_api ++ file_techs)
    {:ok, all_techs}
  end

  @impl true
  def fetch_file(credentials, repo_slug, path, branch \\ "main") do
    workspace = get_workspace(credentials)
    client = build_client(credentials)
    repo_path = resolve_repo_path(workspace, repo_slug)

    case Req.get(client,
           url: "/repos/#{repo_path}/contents/#{path}",
           headers: [{"accept", "application/vnd.github.raw"}],
           params: [ref: branch]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, Jason.encode!(body)}

      {:ok, %Req.Response{status: 404}} ->
        {:error, "File '#{path}' not found on branch '#{branch}'"}

      {:ok, %Req.Response{status: status, body: body}} ->
        msg = extract_error_message(body) || "Failed to fetch file (HTTP #{status})"
        {:error, msg}

      {:error, reason} ->
        {:error, "GitHub connection error: #{inspect(reason)}"}
    end
  end

  # ── Internal Helpers ─────────────────────────────────────────────────────────

  @doc """
  Builds an authenticated Req client for the GitHub REST API.
  Uses Bearer token authentication with Personal Access Tokens.
  """
  @spec build_client(map() | keyword()) :: Req.Request.t()
  def build_client(credentials) when is_list(credentials), do: build_client(Map.new(credentials))

  def build_client(credentials) when is_map(credentials) do
    token = normalize_param(Map.get(credentials, :token) || Map.get(credentials, "token"))

    headers = [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "Ravner-Security-Scanner/1.0"},
      {"x-github-api-version", "2022-11-28"}
    ]

    headers =
      if token && token != "" do
        [{"authorization", "Bearer #{token}"} | headers]
      else
        headers
      end

    Req.new(base_url: @base_url, headers: headers)
  end

  defp get_workspace(credentials) do
    normalize_param(Map.get(credentials, :workspace) || Map.get(credentials, "workspace"))
  end

  defp resolve_repo_path(workspace, repo_slug) do
    if String.contains?(repo_slug, "/") do
      repo_slug
    else
      "#{workspace}/#{repo_slug}"
    end
  end

  defp map_repository(item) do
    %Repository{
      name: item["name"],
      full_name: item["full_name"] || item["name"],
      url: item["html_url"] || "",
      clone_url: item["clone_url"],
      provider: :github,
      description: item["description"],
      main_language: item["language"],
      default_branch: item["default_branch"] || "main",
      is_private: Map.get(item, "private", true),
      updated_at: parse_datetime(item["updated_at"])
    }
  end

  defp map_commit(item) do
    hash = item["sha"] || ""
    commit_data = item["commit"] || %{}
    author_data = commit_data["author"] || %{}

    %Commit{
      hash: hash,
      short_hash: String.slice(hash, 0, 7),
      message: String.trim(commit_data["message"] || ""),
      author_name: author_data["name"],
      author_email: author_data["email"],
      committed_at: parse_datetime(author_data["date"]),
      url: item["html_url"]
    }
  end

  defp maybe_filter_search(repos, nil), do: repos
  defp maybe_filter_search(repos, ""), do: repos

  defp maybe_filter_search(repos, search) do
    q = String.downcase(search)

    Enum.filter(repos, fn r ->
      String.contains?(String.downcase(r.name), q) or
        (r.description && String.contains?(String.downcase(r.description), q)) or
        (r.main_language && String.contains?(String.downcase(r.main_language), q))
    end)
  end

  defp normalize_param(nil), do: nil

  defp normalize_param(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_param(val), do: val

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp extract_error_message(%{"message" => msg}) when is_binary(msg), do: msg
  defp extract_error_message(_), do: nil
end
