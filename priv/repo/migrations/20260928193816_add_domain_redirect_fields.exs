defmodule Ravner.Repo.Migrations.AddDomainRedirectFields do
  use Ecto.Migration

  def change do
    alter table(:domains) do
      add :redirect_target_url, :string
      add :redirect_target_domain_id, references(:domains, on_delete: :nilify_all)
    end

    create index(:domains, [:redirect_target_domain_id])
  end
end
