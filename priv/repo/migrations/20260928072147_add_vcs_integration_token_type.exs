defmodule Ravner.Repo.Migrations.AddVcsIntegrationTokenType do
  use Ecto.Migration

  def change do
    alter table(:vcs_integrations) do
      add :token_type, :string, default: "workspace"
      add :repo_slug, :string
      remove :username, :string
    end
  end
end
