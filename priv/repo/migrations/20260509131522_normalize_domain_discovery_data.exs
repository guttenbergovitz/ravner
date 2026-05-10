defmodule Ravner.Repo.Migrations.NormalizeDomainDiscoveryData do
  use Ecto.Migration

  def change do
    # 1. DNS Records
    create table(:domain_dns_records) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :value, :text, null: false
      add :ttl, :integer
      timestamps(type: :utc_datetime)
    end

    create index(:domain_dns_records, [:domain_id])

    # 2. Tech Evidence
    create table(:domain_tech_evidence) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :version, :string
      add :source, :string
      add :confidence, :integer
      timestamps(type: :utc_datetime)
    end

    create index(:domain_tech_evidence, [:domain_id])

    # 3. Discovered URLs
    create table(:domain_discovered_urls) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :url, :text, null: false
      add :status, :integer
      add :content_type, :string
      add :source, :string
      timestamps(type: :utc_datetime)
    end

    create index(:domain_discovered_urls, [:domain_id])

    # 4. Clean up domain_metadata
    alter table(:domain_metadata) do
      remove :dns_records, {:array, :map}
      remove :tech_evidence, {:array, :map}
      remove :discovered_urls, {:array, :map}
    end
  end
end
