defmodule Ravner.Repo.Migrations.CreateDigitalLandscapeTables do
  use Ecto.Migration

  def change do
    # 1. Registrars
    create table(:registrars) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :account_id, :string
      add :portal_url, :string
      add :notes, :text

      timestamps()
    end

    create unique_index(:registrars, [:name])
    create unique_index(:registrars, [:slug])

    # 2. Hosting Environments
    create table(:hosting_environments) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :provider, :string, null: false, default: "aws"
      add :environment_tier, :string, null: false, default: "production"
      add :region, :string
      add :notes, :text

      timestamps()
    end

    create unique_index(:hosting_environments, [:slug])

    # 3. Network Access Boundaries
    create table(:network_accesses) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :access_level, :string, null: false, default: "public_internet"
      add :vpn_gateway_name, :string
      add :notes, :text

      timestamps()
    end

    create unique_index(:network_accesses, [:slug])

    # 4. External Services & Managed Platforms (gadget.dev, fivetran, etc.)
    create table(:external_services) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :service_type, :string, null: false, default: "saas"
      add :url, :string
      add :notes, :text

      timestamps()
    end

    create unique_index(:external_services, [:slug])

    # 5. Value Streams
    create table(:value_streams) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :stage, :string, default: "active"
      add :criticality, :string, default: "operational"
      add :brand_id, references(:brands, on_delete: :nilify_all)
      add :business_owner_id, references(:people, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:value_streams, [:slug])
    create index(:value_streams, [:brand_id])

    # 6. Business Capabilities
    create table(:business_capabilities) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :category, :string
      add :description, :text

      timestamps()
    end

    create unique_index(:business_capabilities, [:slug])

    # 7. Applications (Core Workload)
    create table(:applications) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :app_type, :string, null: false, default: "website"
      add :lifecycle_state, :string, null: false, default: "active"
      add :criticality, :string, null: false, default: "operational"
      add :description, :text
      add :notes, :text
      add :project_id, references(:projects, on_delete: :nilify_all)
      add :hosting_environment_id, references(:hosting_environments, on_delete: :nilify_all)
      add :network_access_id, references(:network_accesses, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:applications, [:slug])
    create index(:applications, [:project_id])
    create index(:applications, [:hosting_environment_id])
    create index(:applications, [:network_access_id])

    # 8. Datastores
    create table(:datastores) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :store_type, :string, null: false, default: "postgresql"
      add :role, :string, null: false, default: "primary_database"
      add :application_id, references(:applications, on_delete: :nilify_all)
      add :hosting_environment_id, references(:hosting_environments, on_delete: :nilify_all)
      add :notes, :text

      timestamps()
    end

    create unique_index(:datastores, [:slug])
    create index(:datastores, [:application_id])
    create index(:datastores, [:hosting_environment_id])

    # 9. Architecture Constraints (Policy-as-Code)
    create table(:architecture_constraints) do
      add :name, :string, null: false
      add :category, :string, null: false, default: "perimeter"
      add :rule_type, :string, null: false
      add :enforcement_level, :string, null: false, default: "mandatory"
      add :compliance_status, :string, null: false, default: "unknown"
      add :parameters, :map, default: %{}
      add :last_evaluated_at, :utc_datetime
      add :application_id, references(:applications, on_delete: :nilify_all)

      timestamps()
    end

    create index(:architecture_constraints, [:application_id])
    create index(:architecture_constraints, [:rule_type])

    # 10. Join Tables
    create table(:application_value_streams, primary_key: false) do
      add :application_id, references(:applications, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :value_stream_id, references(:value_streams, on_delete: :delete_all),
        null: false,
        primary_key: true

      timestamps()
    end

    create table(:application_capabilities, primary_key: false) do
      add :application_id, references(:applications, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :business_capability_id, references(:business_capabilities, on_delete: :delete_all),
        null: false,
        primary_key: true

      timestamps()
    end

    create table(:application_external_services, primary_key: false) do
      add :application_id, references(:applications, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :external_service_id, references(:external_services, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :integration_type, :string, default: "api"
      timestamps()
    end

    # 11. Alter Existing Tables to Link to Applications & Registrars
    alter table(:domains) do
      add :application_id, references(:applications, on_delete: :nilify_all)
      add :registrar_id, references(:registrars, on_delete: :nilify_all)
    end

    create index(:domains, [:application_id])
    create index(:domains, [:registrar_id])

    alter table(:project_repositories) do
      add :application_id, references(:applications, on_delete: :nilify_all)
    end

    create index(:project_repositories, [:application_id])

    alter table(:projects) do
      add :project_type, :string, default: "customer_facing"
    end
  end
end
