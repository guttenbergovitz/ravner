defmodule Ravner.Integrations.VCS.GitLab do
  @moduledoc """
  GitLab REST API v4 adapter.
  Implements `Ravner.Integrations.VCS.Adapter` using `:req`.
  Supports GitLab.com and self-hosted GitLab instances via Project/Group/Personal Access Tokens.
  """

  @behaviour Ravner.Integrations.VCS.Adapter

  alias Ravner.Integrations.VCS.Commit
  alias Ravner.Integrations.VCS.Repository
  alias Ravner.Integrations.VCS.TechDetector

  @default_base_url "https://gitlab.com/api/v4"

  @impl true
  def test_connection(credentials) do
    workspace = get_workspace(credentials)
    client = build_client(credentials)

    cond do
      is_binary(workspace) and workspace != "" ->
        encoded_group = URI.encode_www_form(workspace)

        case Req.get(client, url: "/groups/#{encoded_group}") do
          {:ok, %Req.Response{status: 200}} ->
            :ok

          {:ok, %Req.Response{status: 404}} ->
            # Fallback check against user endpoint
            case Req.get(client, url: "/users", params: [username: workspace]) do
              {:ok, %Req.Response{status: 200, body: [_ | _]}} ->
                :ok

              {:ok, %Req.Response{status: 200, body: []}} ->
                {:error, "GitLab group or user '#{workspace}' not found"}

              {:ok, %Req.Response{status: status, body: body}} ->
                msg = extract_error_message(body) || "GitLab API error (HTTP #{status})"
                {:error, msg}

              {:error, reason} ->
                {:error, "Failed to connect to GitLab: #{inspect(reason)}"}
            end

          {:ok, %Req.Response{status: 401}} ->
            {:error, "Authentication failed: invalid GitLab Access Token"}

          {:ok, %Req.Response{status: 403}} ->
            {:error, "Access denied: check token permissions (read_api, read_repository)"}

          {:ok, %Req.Response{status: status, body: body}} ->
            msg = extract_error_message(body) || "GitLab API error (HTTP #{status})"
            {:error, msg}

          {:error, reason} ->
            {:error, "Failed to connect to GitLab: #{inspect(reason)}"}
        end

      true ->
        case Req.get(client, url: "/user") do
          {:ok, %Req.Response{status: 200}} ->
            :ok

          {:ok, %Req.Response{status: 401}} ->
            {:error, "Authentication failed: invalid GitLab Access Token"}

          {:ok, %Req.Response{status: status, body: body}} ->
            msg = extract_error_message(body) || "GitLab API error (HTTP #{status})"
            {:error, msg}

          {:error, reason} ->
            {:error, "Failed to connect to GitLab: #{inspect(reason)}"}
        end
    end
  end

  @impl true
  def list_repositories(credentials, opts \\ []) do
    workspace = get_workspace(credentials)
    client = build_client(credentials)
    limit = Keyword.get(opts, :limit, 50)
    search = Keyword.get(opts, :search)

    {url, base_params} =
      cond do
        is_binary(workspace) and workspace != "" ->
          encoded = URI.encode_www_form(workspace)
          {"/groups/#{encoded}/projects", [include_subgroups: true]}

        true ->
          {"/projects", [membership: true]}
      end

    params =
      base_params ++
        [
          per_page: min(limit, 100),
          order_by: "updated_at",
          sort: "desc"
        ]

    params =
      if search && search != "" do
        Keyword.put(params, :search, search)
      else
        params
      end

    case Req.get(client, url: url, params: params) do
      {:ok, %Req.Response{status: 200, body: items}} when is_list(items) ->
        {:ok, Enum.map(items, &map_repository/1)}

      {:ok, %Req.Response{status: status, body: body}} ->
        msg = extract_error_message(body) || "Failed to list repositories (HTTP #{status})"
        {:error, msg}

      {:error, reason} ->
        {:error, "GitLab connection error: #{inspect(reason)}"}
    end
  end

  @impl true
  def get_repository(credentials, repo_slug) do
    workspace = get_workspace(credentials)
    client = build_client(credentials)
    project_path = resolve_project_path(workspace, repo_slug)
    encoded = URI.encode_www_form(project_path)

    case Req.get(client, url: "/projects/#{encoded}") do
      {:ok, %Req.Response{status: 200, body: item}} ->
        {:ok, map_repository(item)}

      {:ok, %Req.Response{status: 404}} ->
        {:error, "Repository '#{project_path}' not found on GitLab"}

      {:ok, %Req.Response{status: status, body: body}} ->
        msg = extract_error_message(body) || "Failed to fetch repository (HTTP #{status})"
        {:error, msg}

      {:error, reason} ->
        {:error, "GitLab connection error: #{inspect(reason)}"}
    end
  end

  @impl true
  def list_commits(credentials, repo_slug, opts \\ []) do
    workspace = get_workspace(credentials)
    client = build_client(credentials)
    project_path = resolve_project_path(workspace, repo_slug)
    encoded = URI.encode_www_form(project_path)
    limit = Keyword.get(opts, :limit, 10)

    params = [per_page: min(limit, 100)]

    case Req.get(client, url: "/projects/#{encoded}/repository/commits", params: params) do
      {:ok, %Req.Response{status: 200, body: items}} when is_list(items) ->
        {:ok, Enum.map(items, &map_commit/1)}

      {:ok, %Req.Response{status: 404}} ->
        {:error, "Repository '#{project_path}' not found on GitLab"}

      {:ok, %Req.Response{status: status, body: body}} ->
        msg = extract_error_message(body) || "Failed to fetch commits (HTTP #{status})"
        {:error, msg}

      {:error, reason} ->
        {:error, "GitLab connection error: #{inspect(reason)}"}
    end
  end

  @impl true
  def detect_tech_stack(credentials, repo_slug, default_branch \\ "main") do
    workspace = get_workspace(credentials)
    client = build_client(credentials)
    project_path = resolve_project_path(workspace, repo_slug)
    encoded = URI.encode_www_form(project_path)

    # 1. Fetch language statistics from GitLab API
    detected_from_api =
      case Req.get(client, url: "/projects/#{encoded}/languages") do
        {:ok, %Req.Response{status: 200, body: %{} = langs}} ->
          Map.keys(langs)

        _ ->
          []
      end

    # 2. Inspect root repository tree for manifest files
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
      "docker-compose.yml",
      ".gitlab-ci.yml"
    ]

    discovered_files =
      case Req.get(client,
             url: "/projects/#{encoded}/repository/tree",
             params: [ref: default_branch, per_page: 100]
           ) do
        {:ok, %Req.Response{status: 200, body: tree}} when is_list(tree) ->
          tree
          |> Enum.map(& &1["name"])
          |> Enum.filter(&(&1 in manifest_files))
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    # 3. If package.json is present, parse dependencies
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
    project_path = resolve_project_path(workspace, repo_slug)
    encoded_project = URI.encode_www_form(project_path)
    encoded_file = URI.encode_www_form(path)

    case Req.get(client,
           url: "/projects/#{encoded_project}/repository/files/#{encoded_file}/raw",
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
        {:error, "GitLab connection error: #{inspect(reason)}"}
    end
  end

  # ── Internal Helpers ─────────────────────────────────────────────────────────

  @doc """
  Builds an authenticated Req client for GitLab API.
  Uses PRIVATE-TOKEN header or Bearer authorization header.
  """
  @spec build_client(map() | keyword()) :: Req.Request.t()
  def build_client(credentials) when is_list(credentials), do: build_client(Map.new(credentials))

  def build_client(credentials) when is_map(credentials) do
    token = normalize_param(Map.get(credentials, :token) || Map.get(credentials, "token"))
    settings = Map.get(credentials, :settings) || Map.get(credentials, "settings") || %{}

    base_url =
      normalize_param(settings[:base_url] || settings["base_url"]) || @default_base_url

    headers = [
      {"accept", "application/json"},
      {"user-agent", "Ravner-Security-Scanner/1.0"}
    ]

    headers =
      if token && token != "" do
        [{"private-token", token} | headers]
      else
        headers
      end

    Req.new(base_url: base_url, headers: headers)
  end

  defp get_workspace(credentials) do
    normalize_param(Map.get(credentials, :workspace) || Map.get(credentials, "workspace"))
  end

  defp resolve_project_path(workspace, repo_slug) do
    if String.contains?(repo_slug, "/") do
      repo_slug
    else
      "#{workspace}/#{repo_slug}"
    end
  end

  defp map_repository(item) do
    %Repository{
      name: item["name"] || item["path"],
      full_name: item["path_with_namespace"] || item["name"],
      url: item["web_url"] || "",
      clone_url: item["http_url_to_repo"],
      provider: :gitlab,
      description: item["description"],
      main_language: nil,
      default_branch: item["default_branch"] || "main",
      is_private: item["visibility"] == "private",
      updated_at: parse_datetime(item["last_activity_at"])
    }
  end

  defp map_commit(item) do
    hash = item["id"] || ""

    %Commit{
      hash: hash,
      short_hash: String.slice(hash, 0, 8),
      message: String.trim(item["message"] || item["title"] || ""),
      author_name: item["author_name"],
      author_email: item["author_email"],
      committed_at: parse_datetime(item["committed_date"]),
      url: item["web_url"]
    }
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
  defp extract_error_message(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error_message(_), do: nil
end
