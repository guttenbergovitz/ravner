defmodule Ravner.Integrations.VCS.Bitbucket do
  @moduledoc """
  Bitbucket Cloud REST API v2 adapter.
  Implements `Ravner.Integrations.VCS.Adapter` using `:req`.
  """

  @behaviour Ravner.Integrations.VCS.Adapter

  alias Ravner.Integrations.VCS.Commit
  alias Ravner.Integrations.VCS.Repository

  @base_url "https://api.bitbucket.org/2.0"

  @impl true
  def test_connection(credentials) do
    workspace = get_workspace(credentials)
    token_type = get_token_type(credentials)
    repo_slug = get_repo_slug(credentials)

    cond do
      is_nil(workspace) or workspace == "" ->
        {:error, "Workspace is required for Bitbucket integration"}

      token_type == "repository" and (is_nil(repo_slug) or repo_slug == "") ->
        {:error, "Repository slug is required for repository-scoped tokens"}

      true ->
        client = build_client(credentials)

        # Repository tokens can only access specific repo, not list workspace repos
        url =
          if token_type == "repository" do
            "/repositories/#{workspace}/#{repo_slug}"
          else
            "/repositories/#{workspace}"
          end

        params = if token_type == "repository", do: [], else: [pagelen: 1]

        case Req.get(client, url: url, params: params) do
          {:ok, %Req.Response{status: 200}} ->
            :ok

          {:ok, %Req.Response{status: 401}} ->
            {:error, "Authentication failed: invalid Bitbucket token"}

          {:ok, %Req.Response{status: 403}} ->
            {:error, "Access denied: check repository read permissions on your Bitbucket token"}

          {:ok, %Req.Response{status: 404}} ->
            if token_type == "repository" do
              {:error, "Repository '#{workspace}/#{repo_slug}' not found or token lacks access"}
            else
              {:error, "Bitbucket workspace '#{workspace}' not found"}
            end

          {:ok, %Req.Response{status: status, body: body}} ->
            msg = extract_error_message(body) || "Bitbucket API error (HTTP #{status})"
            {:error, msg}

          {:error, reason} ->
            {:error, "Failed to connect to Bitbucket: #{inspect(reason)}"}
        end
    end
  end

  @impl true
  def list_repositories(credentials, opts \\ []) do
    workspace = get_workspace(credentials)

    if is_nil(workspace) or workspace == "" do
      {:error, "Workspace is required for Bitbucket integration"}
    else
      client = build_client(credentials)
      search = Keyword.get(opts, :search)
      limit = Keyword.get(opts, :limit, 50)

      params = [
        pagelen: min(limit, 100),
        sort: "-updated_on"
      ]

      params =
        if search && search != "" do
          # Bitbucket query filter
          Keyword.put(params, :q, "name ~ \"#{search}\"")
        else
          params
        end

      case Req.get(client, url: "/repositories/#{workspace}", params: params) do
        {:ok, %Req.Response{status: 200, body: %{"values" => items}}} when is_list(items) ->
          repos = Enum.map(items, &map_repository/1)
          {:ok, repos}

        {:ok, %Req.Response{status: status, body: body}} ->
          msg = extract_error_message(body) || "Failed to list repositories (HTTP #{status})"
          {:error, msg}

        {:error, reason} ->
          {:error, "Bitbucket connection error: #{inspect(reason)}"}
      end
    end
  end

  @impl true
  def get_repository(credentials, repo_slug) do
    workspace = get_workspace(credentials)
    client = build_client(credentials)

    case Req.get(client, url: "/repositories/#{workspace}/#{repo_slug}") do
      {:ok, %Req.Response{status: 200, body: item}} ->
        {:ok, map_repository(item)}

      {:ok, %Req.Response{status: 404}} ->
        {:error, "Repository '#{workspace}/#{repo_slug}' not found"}

      {:ok, %Req.Response{status: status, body: body}} ->
        msg = extract_error_message(body) || "Failed to fetch repository (HTTP #{status})"
        {:error, msg}

      {:error, reason} ->
        {:error, "Bitbucket connection error: #{inspect(reason)}"}
    end
  end

  @impl true
  def list_commits(credentials, repo_slug, opts \\ []) do
    workspace = get_workspace(credentials)
    client = build_client(credentials)
    limit = Keyword.get(opts, :limit, 10)

    case Req.get(client,
           url: "/repositories/#{workspace}/#{repo_slug}/commits",
           params: [pagelen: limit]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"values" => items}}} when is_list(items) ->
        commits = Enum.map(items, &map_commit/1)
        {:ok, commits}

      {:ok, %Req.Response{status: status, body: body}} ->
        msg = extract_error_message(body) || "Failed to fetch commits (HTTP #{status})"
        {:error, msg}

      {:error, reason} ->
        {:error, "Bitbucket connection error: #{inspect(reason)}"}
    end
  end

  @impl true
  def detect_tech_stack(credentials, repo_slug, default_branch \\ "main") do
    workspace = get_workspace(credentials)
    client = build_client(credentials)

    # List root directory entries
    case Req.get(client,
           url: "/repositories/#{workspace}/#{repo_slug}/src/#{default_branch}/",
           params: [pagelen: 100]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"values" => entries}}} when is_list(entries) ->
        file_names =
          entries
          |> Enum.map(& &1["path"])
          |> Enum.filter(&is_binary/1)
          |> MapSet.new()

        package_techs =
          if MapSet.member?(file_names, "package.json") do
            inspect_package_json(client, workspace, repo_slug, default_branch)
          else
            []
          end

        techs = Enum.uniq(detect_from_files(file_names) ++ package_techs)
        {:ok, techs}

      {:ok, %Req.Response{status: 404}} ->
        # Try master branch if main failed
        if default_branch == "main" do
          detect_tech_stack(credentials, repo_slug, "master")
        else
          {:ok, []}
        end

      _ ->
        {:ok, []}
    end
  end

  @impl true
  def fetch_file(credentials, repo_slug, path, branch \\ "main") do
    workspace = get_workspace(credentials)
    client = build_client(credentials)

    case Req.get(client, url: "/repositories/#{workspace}/#{repo_slug}/src/#{branch}/#{path}") do
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
        {:error, "Bitbucket connection error: #{inspect(reason)}"}
    end
  end

  @doc """
  Detects technologies from a list/set of filenames and optional package.json map/string.
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

  defp inspect_package_json(client, workspace, repo_slug, branch) do
    case Req.get(client,
           url: "/repositories/#{workspace}/#{repo_slug}/src/#{branch}/package.json"
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_package_json_dependencies(body)

      _ ->
        []
    end
  end

  defp parse_package_json_dependencies(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} -> parse_package_json_dependencies(json)
      _ -> []
    end
  end

  defp parse_package_json_dependencies(%{} = json) do
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

  defp parse_package_json_dependencies(_), do: []

  defp detect_from_files(files) do
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
      {"bitbucket-pipelines.yml", ["Bitbucket Pipelines"]}
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

  @doc """
  Builds an authenticated Req client for Bitbucket API from credentials.
  Supports Access Tokens (Bearer) and App Passwords (Basic Auth).
  """
  @spec build_client(map() | keyword()) :: Req.Request.t()
  def build_client(credentials) when is_list(credentials) do
    build_client(Map.new(credentials))
  end

  def build_client(credentials) when is_map(credentials) do
    username =
      normalize_param(Map.get(credentials, :username) || Map.get(credentials, "username"))

    token = normalize_param(Map.get(credentials, :token) || Map.get(credentials, "token"))

    app_password =
      normalize_param(Map.get(credentials, :app_password) || Map.get(credentials, "app_password"))

    auth_type =
      normalize_param(Map.get(credentials, :auth_type) || Map.get(credentials, "auth_type"))

    auth =
      cond do
        # Explicit Bearer token (Repository or Workspace Access Token)
        auth_type in ["bearer", "token"] and (token || app_password) ->
          {:bearer, token || app_password}

        # Basic Auth: only when a non-empty username is present
        username != nil and (app_password || token) ->
          {:basic, "#{username}:#{app_password || token}"}

        # Access token default: token without username is treated as Bearer token
        token || app_password ->
          {:bearer, token || app_password}

        true ->
          nil
      end

    base_opts = [base_url: @base_url]
    opts = if auth, do: Keyword.put(base_opts, :auth, auth), else: base_opts
    custom_opts = Application.get_env(:ravner, :bitbucket_req_opts, [])

    Req.new(Keyword.merge(opts, custom_opts))
  end

  defp normalize_param(nil), do: nil
  defp normalize_param(""), do: nil

  defp normalize_param(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_param(val), do: val

  defp get_workspace(credentials) do
    Map.get(credentials, :workspace) || Map.get(credentials, "workspace")
  end

  defp get_token_type(credentials) do
    Map.get(credentials, :token_type) || Map.get(credentials, "token_type") || "workspace"
  end

  defp get_repo_slug(credentials) do
    Map.get(credentials, :repo_slug) || Map.get(credentials, "repo_slug")
  end

  defp map_repository(item) do
    clone_url =
      item
      |> get_in(["links", "clone"])
      |> case do
        links when is_list(links) ->
          Enum.find_value(links, fn l ->
            if l["name"] == "https", do: l["href"]
          end)

        _ ->
          nil
      end

    %Repository{
      name: item["name"],
      full_name: item["full_name"] || item["name"],
      url: get_in(item, ["links", "html", "href"]) || "",
      clone_url: clone_url,
      provider: :bitbucket,
      description: item["description"],
      main_language: item["language"],
      default_branch: get_in(item, ["mainbranch", "name"]) || "main",
      is_private: Map.get(item, "is_private", true),
      updated_at: parse_datetime(item["updated_on"])
    }
  end

  defp map_commit(item) do
    hash = item["hash"] || ""

    %Commit{
      hash: hash,
      short_hash: String.slice(hash, 0, 7),
      message: String.trim(item["message"] || ""),
      author_name:
        get_in(item, ["author", "user", "display_name"]) || parse_raw_author_name(item["author"]),
      author_email: parse_raw_author_email(item["author"]),
      committed_at: parse_datetime(item["date"]),
      url: get_in(item, ["links", "html", "href"])
    }
  end

  defp parse_raw_author_name(%{"raw" => raw}) when is_binary(raw) do
    case Regex.run(~r/^(.*?)\s*<.*>$/, raw) do
      [_, name] -> String.trim(name)
      _ -> raw
    end
  end

  defp parse_raw_author_name(_), do: nil

  defp parse_raw_author_email(%{"raw" => raw}) when is_binary(raw) do
    case Regex.run(~r/<([^>]+)>/, raw) do
      [_, email] -> email
      _ -> nil
    end
  end

  defp parse_raw_author_email(_), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp extract_error_message(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error_message(%{"message" => msg}), do: msg
  defp extract_error_message(_), do: nil
end
