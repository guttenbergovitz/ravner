defmodule Ravner.Integrations.VcsIntegration do
  @moduledoc """
  Ecto schema for storing version control system (VCS) integrations.
  Holds workspace-level or organization-level credentials (e.g. Bitbucket, GitHub, GitLab)
  used by Ravner to securely browse repositories and inspect commit/tech stack metadata
  without exposing tokens to end-user clients.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          provider: String.t() | nil,
          workspace: String.t() | nil,
          token_type: String.t() | nil,
          repo_slug: String.t() | nil,
          token: String.t() | nil,
          active: boolean(),
          settings: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @providers ~w(bitbucket github gitlab)

  @token_types ~w(workspace repository)

  schema "vcs_integrations" do
    field(:name, :string)
    field(:provider, :string, default: "bitbucket")
    field(:workspace, :string)
    field(:token_type, :string, default: "workspace")
    field(:repo_slug, :string)
    field(:token, :string, redact: true)
    field(:active, :boolean, default: true)
    field(:settings, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a VCS integration.
  Preserves existing token when updating if token input is blank.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(integration, attrs) do
    # When updating an existing integration and token is omitted/blank, preserve existing token
    attrs =
      if integration.id &&
           (is_nil(attrs["token"]) || attrs["token"] == "" ||
              is_nil(attrs[:token]) || attrs[:token] == "") do
        attrs
        |> Map.delete("token")
        |> Map.delete(:token)
      else
        attrs
      end

    required =
      if integration.id do
        [:name, :provider, :workspace]
      else
        [:name, :provider, :workspace, :token]
      end

    integration
    |> cast(attrs, [
      :name,
      :provider,
      :workspace,
      :token_type,
      :repo_slug,
      :token,
      :active,
      :settings
    ])
    |> validate_required(required)
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:token_type, @token_types)
    |> validate_repo_slug_required()
    |> unique_constraint([:provider, :workspace],
      name: :vcs_integrations_workspace_token_unique,
      message: "workspace token already configured - use Browse VCS to link repos"
    )
    |> unique_constraint([:provider, :workspace, :repo_slug],
      name: :vcs_integrations_repository_token_unique,
      message: "repository token already configured for this repo"
    )
  end

  # Require repo_slug when token_type is "repository"
  defp validate_repo_slug_required(changeset) do
    token_type = get_field(changeset, :token_type)

    if token_type == "repository" do
      validate_required(changeset, [:repo_slug], message: "is required for repository tokens")
    else
      changeset
    end
  end

  @doc "Returns allowed token types."
  @spec token_types() :: [String.t()]
  def token_types, do: @token_types

  @doc """
  Returns allowed providers list.
  """
  @spec providers() :: [String.t()]
  def providers, do: @providers
end
