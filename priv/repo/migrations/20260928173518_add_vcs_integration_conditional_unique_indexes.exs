defmodule Ravner.Repo.Migrations.AddVcsIntegrationConditionalUniqueIndexes do
  use Ecto.Migration

  def change do
    # Drop old simple unique index if exists
    drop_if_exists unique_index(:vcs_integrations, [:provider, :workspace])

    # Workspace tokens: one per provider+workspace
    create unique_index(:vcs_integrations, [:provider, :workspace],
             where: "token_type = 'workspace'",
             name: :vcs_integrations_workspace_token_unique
           )

    # Repository tokens: one per provider+workspace+repo_slug
    create unique_index(:vcs_integrations, [:provider, :workspace, :repo_slug],
             where: "token_type = 'repository'",
             name: :vcs_integrations_repository_token_unique
           )
  end
end
