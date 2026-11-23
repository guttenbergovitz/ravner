defmodule Ravner.Integrations.VCS do
  @moduledoc """
  The VCS (Version Control Systems) context and facade.
  Manages integrations with Bitbucket, GitHub, and GitLab, and provides
  unified repository browsing, commit history, and tech stack detection.
  """

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Integrations.VcsIntegration
  alias Ravner.Integrations.VCS.{Bitbucket, Commit, GitHub, GitLab, Repository}
  alias Ravner.Inventory.ProjectRepository

  # ── Integrations Management ──────────────────────────────────────────────────

  @doc """
  Lists all configured VCS integrations.
  """
  @spec list_integrations() :: [VcsIntegration.t()]
  def list_integrations do
    Repo.all(from(i in VcsIntegration, order_by: [asc: i.name]))
  end

  @doc """
  Gets a single VCS integration by ID.
  """
  @spec get_integration!(integer() | String.t()) :: VcsIntegration.t()
  def get_integration!(id), do: Repo.get!(VcsIntegration, id)

  @doc """
  Creates a new VCS integration.
  """
  @spec create_integration(map()) :: {:ok, VcsIntegration.t()} | {:error, Ecto.Changeset.t()}
  def create_integration(attrs) do
    %VcsIntegration{}
    |> VcsIntegration.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a VCS integration.
  """
  @spec update_integration(VcsIntegration.t(), map()) ::
          {:ok, VcsIntegration.t()} | {:error, Ecto.Changeset.t()}
  def update_integration(%VcsIntegration{} = integration, attrs) do
    integration
    |> VcsIntegration.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a VCS integration.
  """
  @spec delete_integration(VcsIntegration.t()) ::
          {:ok, VcsIntegration.t()} | {:error, Ecto.Changeset.t()}
  def delete_integration(%VcsIntegration{} = integration) do
    Repo.delete(integration)
  end

  @doc """
  Returns a changeset for tracking VCS integration changes.
  """
  @spec change_integration(VcsIntegration.t(), map()) :: Ecto.Changeset.t()
  def change_integration(%VcsIntegration{} = integration, attrs \\ %{}) do
    VcsIntegration.changeset(integration, attrs)
  end

  @doc """
  Returns a status map describing the active VCS provider configuration and its source.
  The returned status explicitly redacts tokens and provides a safe masked token preview.
  """
  @spec status(String.t() | atom()) :: %{
          configured?: boolean(),
          source: :database | :env | :none,
          provider: String.t(),
          workspace: String.t() | nil,
          token_type: String.t() | nil,
          repo_slug: String.t() | nil,
          token_configured?: boolean(),
          token_preview: String.t() | nil,
          active_integration_id: integer() | nil,
          active_integration: VcsIntegration.t() | nil
        }
  def status(provider \\ "bitbucket") do
    provider_str = to_string(provider)

    db_integration =
      from(i in VcsIntegration,
        where: i.provider == ^provider_str and i.active == true,
        order_by: [desc: i.inserted_at],
        limit: 1
      )
      |> Repo.one()

    cond do
      db_integration ->
        %{
          configured?: true,
          source: :database,
          provider: provider_str,
          workspace: db_integration.workspace,
          token_type: db_integration.token_type || "workspace",
          repo_slug: db_integration.repo_slug,
          active_integration_id: db_integration.id,
          token_configured?: is_binary(db_integration.token) and db_integration.token != "",
          token_preview: mask_token(db_integration.token),
          active_integration: %{db_integration | token: nil}
        }

      env_config = get_env_credentials(provider_str) ->
        %{
          configured?: true,
          source: :env,
          provider: provider_str,
          workspace: env_config.workspace,
          token_type: "workspace",
          repo_slug: nil,
          active_integration_id: nil,
          token_configured?: is_binary(env_config[:token]) and env_config[:token] != "",
          token_preview: mask_token(env_config[:token]),
          active_integration: nil
        }

      true ->
        %{
          configured?: false,
          source: :none,
          provider: provider_str,
          workspace: nil,
          token_type: nil,
          repo_slug: nil,
          active_integration_id: nil,
          token_configured?: false,
          token_preview: nil,
          active_integration: nil
        }
    end
  end

  @doc """
  Masks a secret token for safe UI display, preserving only the last 4 characters.
  """
  @spec mask_token(String.t() | nil) :: String.t() | nil
  def mask_token(nil), do: nil
  def mask_token(""), do: nil

  def mask_token(token) when is_binary(token) do
    len = String.length(token)

    if len > 8 do
      "••••••••" <> String.slice(token, -4..-1)
    else
      "••••••••"
    end
  end

  @doc """
  Resolves active credentials for a given provider (e.g. "bitbucket").
  Checks database integrations first; if none active, falls back to environment configuration.
  """
  @spec resolve_credentials(String.t() | atom()) :: map() | nil
  def resolve_credentials(provider \\ "bitbucket") do
    provider_str = to_string(provider)

    # 1. Database check
    db_integration =
      from(i in VcsIntegration,
        where: i.provider == ^provider_str and i.active == true,
        order_by: [desc: i.inserted_at],
        limit: 1
      )
      |> Repo.one()

    cond do
      db_integration ->
        %{
          workspace: db_integration.workspace,
          token: db_integration.token,
          token_type: db_integration.token_type || "workspace",
          repo_slug: db_integration.repo_slug,
          app_password: db_integration.token,
          settings: db_integration.settings || %{}
        }

      # 2. Env config fallback
      env_config = get_env_credentials(provider_str) ->
        env_config

      true ->
        nil
    end
  end

  defp get_env_credentials("bitbucket") do
    workspace = System.get_env("BITBUCKET_WORKSPACE")
    token = System.get_env("BITBUCKET_TOKEN") || System.get_env("BITBUCKET_APP_PASSWORD")

    if workspace && token do
      %{
        provider: "bitbucket",
        workspace: workspace,
        token: token,
        token_type: "workspace",
        repo_slug: nil,
        app_password: token,
        settings: %{}
      }
    else
      nil
    end
  end

  defp get_env_credentials("github") do
    workspace = System.get_env("GITHUB_WORKSPACE") || System.get_env("GITHUB_ORG")
    token = System.get_env("GITHUB_TOKEN") || System.get_env("GITHUB_PAT")

    if token do
      %{
        provider: "github",
        workspace: workspace,
        username: nil,
        token: token,
        app_password: token,
        settings: %{}
      }
    else
      nil
    end
  end

  defp get_env_credentials("gitlab") do
    workspace = System.get_env("GITLAB_WORKSPACE") || System.get_env("GITLAB_GROUP")
    token = System.get_env("GITLAB_TOKEN")
    base_url = System.get_env("GITLAB_BASE_URL")

    if token do
      %{
        provider: "gitlab",
        workspace: workspace,
        username: nil,
        token: token,
        app_password: token,
        settings: if(base_url, do: %{"base_url" => base_url}, else: %{})
      }
    else
      nil
    end
  end

  defp get_env_credentials(_), do: nil

  @doc """
  Returns a sanitized map of active VCS credentials for safe use in LiveView assigns.
  Excludes sensitive tokens and passwords to eliminate any leak vector over websockets.
  """
  @spec safe_active_vcs(String.t() | atom()) ::
          %{
            provider: String.t(),
            workspace: String.t(),
            token_type: String.t(),
            repo_slug: String.t() | nil,
            settings: map()
          }
          | nil
  def safe_active_vcs(provider \\ "bitbucket") do
    provider_str = to_string(provider)

    case resolve_credentials(provider_str) do
      %{workspace: workspace} = creds when is_binary(workspace) and workspace != "" ->
        %{
          provider: provider_str,
          workspace: workspace,
          token_type: Map.get(creds, :token_type, "workspace"),
          repo_slug: Map.get(creds, :repo_slug),
          settings: Map.get(creds, :settings, %{})
        }

      _ ->
        nil
    end
  end

  @doc """
  Returns a list of all active configured VCS providers.
  """
  @spec list_active_vcs() :: [map()]
  def list_active_vcs do
    Enum.map(["bitbucket", "github", "gitlab"], &safe_active_vcs/1)
    |> Enum.reject(&is_nil/1)
  end

  # ── Adapter Operations ───────────────────────────────────────────────────────

  @doc """
  Returns the adapter module for a given provider.
  """
  @spec adapter_for(String.t() | atom()) :: module()
  def adapter_for(provider) when provider in ["bitbucket", :bitbucket], do: Bitbucket
  def adapter_for(provider) when provider in ["github", :github], do: GitHub
  def adapter_for(provider) when provider in ["gitlab", :gitlab], do: GitLab
  def adapter_for(_), do: Bitbucket

  @doc """
  Tests connection to a VCS provider.
  """
  @spec test_connection(String.t() | atom(), map()) :: :ok | {:error, String.t()}
  def test_connection(provider, credentials) do
    adapter = adapter_for(provider)
    adapter.test_connection(credentials)
  end

  @doc """
  Lists repositories from the connected provider.
  """
  @spec list_repositories(String.t() | atom(), map() | nil, keyword()) ::
          {:ok, [Repository.t()]} | {:error, String.t()}
  def list_repositories(provider \\ "bitbucket", credentials \\ nil, opts \\ []) do
    creds = credentials || resolve_credentials(provider)

    if is_nil(creds) do
      {:error,
       "No active #{provider} integration found. Please configure Bitbucket credentials first."}
    else
      adapter = adapter_for(provider)
      adapter.list_repositories(creds, opts)
    end
  end

  @doc """
  Fetches repository details.
  """
  @spec get_repository(String.t() | atom(), String.t(), map() | nil) ::
          {:ok, Repository.t()} | {:error, String.t()}
  def get_repository(provider, repo_slug, credentials \\ nil) do
    creds = credentials || resolve_credentials(provider)

    if is_nil(creds) do
      {:error, "No active #{provider} integration found"}
    else
      adapter = adapter_for(provider)
      adapter.get_repository(creds, repo_slug)
    end
  end

  @doc """
  Lists recent commits for a repository.
  """
  @spec list_commits(String.t() | atom(), String.t(), map() | nil, keyword()) ::
          {:ok, [Commit.t()]} | {:error, String.t()}
  def list_commits(provider, repo_slug, credentials \\ nil, opts \\ []) do
    creds = credentials || resolve_credentials(provider)

    if is_nil(creds) do
      {:error, "No active #{provider} integration found"}
    else
      adapter = adapter_for(provider)
      adapter.list_commits(creds, repo_slug, opts)
    end
  end

  @doc """
  Detects tech stack for a repository.
  """
  @spec detect_tech_stack(String.t() | atom(), String.t(), String.t(), map() | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def detect_tech_stack(provider, repo_slug, default_branch \\ "main", credentials \\ nil) do
    creds = credentials || resolve_credentials(provider)

    if is_nil(creds) do
      {:error, "No active #{provider} integration found"}
    else
      adapter = adapter_for(provider)
      adapter.detect_tech_stack(creds, repo_slug, default_branch)
    end
  end

  @doc """
  Fetches file content from a repository branch.
  """
  @spec fetch_file(
          String.t() | atom(),
          String.t(),
          String.t(),
          String.t(),
          map() | nil
        ) :: {:ok, binary()} | {:error, String.t()}
  def fetch_file(provider, repo_slug, path, branch \\ "main", credentials \\ nil) do
    creds = credentials || resolve_credentials(provider)

    if is_nil(creds) do
      {:error, "No active #{provider} integration found"}
    else
      adapter = adapter_for(provider)
      adapter.fetch_file(creds, repo_slug, path, branch)
    end
  end

  @doc """
  Synchronizes live metadata (latest commit, default branch, detected tech stack)
  for a ProjectRepository and updates it in the database.
  """
  @spec sync_repository_metadata(ProjectRepository.t(), keyword()) ::
          {:ok, ProjectRepository.t()} | {:error, String.t()}
  def sync_repository_metadata(%ProjectRepository{} = repo, opts \\ []) do
    provider = repo.provider || detect_provider_from_url(repo.url)
    repo_slug = repo.external_id || extract_slug_from_url(repo.url)

    if is_nil(repo_slug) do
      {:error, "Unable to determine repository slug from URL '#{repo.url}'"}
    else
      creds = resolve_credentials(provider)

      if is_nil(creds) do
        {:error, "No active integration credentials configured for #{provider}"}
      else
        adapter = adapter_for(provider)

        # 1. Fetch latest commit
        latest_commit =
          case adapter.list_commits(creds, repo_slug, limit: 1) do
            {:ok, [c | _]} -> c
            _ -> nil
          end

        # 2. Detect tech stack
        default_branch = repo.default_branch || "main"

        detected_techs =
          case adapter.detect_tech_stack(creds, repo_slug, default_branch) do
            {:ok, techs} when is_list(techs) -> techs
            _ -> []
          end

        tech_str =
          if detected_techs != [] do
            Enum.join(detected_techs, ", ")
          else
            repo.technology
          end

        main_lang =
          case detected_techs do
            [first | _] -> first
            _ -> repo.main_language
          end

        attrs = %{
          provider: to_string(provider),
          external_id: repo_slug,
          technology: tech_str,
          main_language: main_lang || repo.main_language
        }

        attrs =
          if latest_commit do
            attrs
            |> Map.put(:last_commit_hash, latest_commit.hash)
            |> Map.put(:last_commit_message, latest_commit.message)
            |> Map.put(:last_commit_author, latest_commit.author_name)
            |> Map.put(:last_commit_at, latest_commit.committed_at)
          else
            attrs
          end

        actor = Keyword.get(opts, :actor)

        case Ravner.Inventory.update_project_repository(repo, attrs, actor: actor) do
          {:ok, updated_repo} ->
            enrich_domains_with_tech_stack(updated_repo, detected_techs, provider)
            {:ok, updated_repo}

          error ->
            error
        end
      end
    end
  end

  defp enrich_domains_with_tech_stack(repo, techs, _provider)
       when is_list(techs) and techs != [] do
    domain_ids =
      cond do
        repo.domain_id ->
          [repo.domain_id]

        repo.project_id ->
          Repo.all(
            from(d in Ravner.Domains.Domain,
              where: d.project_id == ^repo.project_id,
              select: d.id
            )
          )

        true ->
          []
      end

    for domain_id <- domain_ids do
      Ravner.Domains.sync_all_vcs_tech_evidence_for_domain(domain_id)
    end
  end

  defp enrich_domains_with_tech_stack(_repo, _techs, _provider), do: :ok

  @doc """
  Auto-detects VCS provider from URL.
  """
  @spec detect_provider_from_url(String.t() | nil) :: String.t()
  def detect_provider_from_url(nil), do: "other"

  def detect_provider_from_url(url) do
    cond do
      String.contains?(url, "bitbucket.org") -> "bitbucket"
      String.contains?(url, "github.com") -> "github"
      String.contains?(url, "gitlab.com") -> "gitlab"
      true -> "other"
    end
  end

  @doc """
  Extracts workspace/repo_slug or org/repo from a URL.
  Examples:
    "https://bitbucket.org/acme/ravner" -> "ravner"
    "git@bitbucket.org:acme/ravner.git" -> "ravner"
  """
  @spec extract_slug_from_url(String.t() | nil) :: String.t() | nil
  def extract_slug_from_url(nil), do: nil

  def extract_slug_from_url(url) do
    clean_url =
      url
      |> String.replace(~r/\.git$/, "")
      |> String.trim_trailing("/")

    case URI.parse(clean_url) do
      %URI{path: path} when is_binary(path) ->
        path
        |> String.split("/", trim: true)
        |> List.last()

      _ ->
        nil
    end
  end
end
