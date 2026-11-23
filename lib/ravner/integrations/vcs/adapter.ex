defmodule Ravner.Integrations.VCS.Adapter do
  @moduledoc """
  Behaviour specification for VCS platform adapters (Bitbucket, GitHub, GitLab).
  """

  alias Ravner.Integrations.VCS.Commit
  alias Ravner.Integrations.VCS.Repository

  @type credentials :: %{
          optional(:workspace) => String.t(),
          optional(:username) => String.t(),
          optional(:token) => String.t(),
          optional(:app_password) => String.t(),
          optional(:settings) => map()
        }

  @callback test_connection(credentials()) :: :ok | {:error, String.t()}

  @callback list_repositories(credentials(), opts :: keyword()) ::
              {:ok, [Repository.t()]} | {:error, String.t()}

  @callback get_repository(credentials(), repo_slug :: String.t()) ::
              {:ok, Repository.t()} | {:error, String.t()}

  @callback list_commits(credentials(), repo_slug :: String.t(), opts :: keyword()) ::
              {:ok, [Commit.t()]} | {:error, String.t()}

  @callback detect_tech_stack(
              credentials(),
              repo_slug :: String.t(),
              default_branch :: String.t()
            ) ::
              {:ok, [String.t()]} | {:error, String.t()}

  @callback fetch_file(
              credentials(),
              repo_slug :: String.t(),
              path :: String.t(),
              branch :: String.t()
            ) ::
              {:ok, binary()} | {:error, String.t()}
end
