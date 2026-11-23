defmodule Ravner.Inventory.Application do
  @moduledoc """
  Ash resource representing a Software Application / Digital Asset (e.g. Website, Storefront, API, CMS, CRM, PIM, ERP, Portal).
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  json_api do
    type("application")

    routes do
      base("/applications")
      get(:read)
      index(:read)
      post(:create)
      patch(:update)
      delete(:destroy)
    end
  end

  postgres do
    table("applications")
    repo(Ravner.Repo)
  end

  paper_trail do
    primary_key_type(:integer)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    reference_source?(false)
  end

  policies do
    policy action_type(:read) do
      authorize_if({Ravner.Accounts.ScopeReadCheck, []})
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(actor_attribute_equals(:role, :editor))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :name,
        :slug,
        :app_type,
        :lifecycle_state,
        :criticality,
        :description,
        :notes,
        :project_id,
        :hosting_environment_id,
        :network_access_id
      ])
    end

    update :update do
      primary?(true)

      accept([
        :name,
        :slug,
        :app_type,
        :lifecycle_state,
        :criticality,
        :description,
        :notes,
        :project_id,
        :hosting_environment_id,
        :network_access_id
      ])
    end

    update :set_lifecycle do
      accept([:lifecycle_state])
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :slug, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :app_type, :string do
      default("website")
      allow_nil?(false)
      public?(true)
    end

    attribute :lifecycle_state, :string do
      default("active")
      allow_nil?(false)
      public?(true)
    end

    attribute :criticality, :string do
      default("operational")
      allow_nil?(false)
      public?(true)
    end

    attribute(:description, :string, public?: true)
    attribute(:notes, :string, public?: true)
    attribute(:project_id, :integer, public?: true)
    attribute(:hosting_environment_id, :integer, public?: true)
    attribute(:network_access_id, :integer, public?: true)

    create_timestamp(:inserted_at, type: :utc_datetime, public?: true)
    update_timestamp(:updated_at, type: :utc_datetime, public?: true)
  end

  relationships do
    belongs_to :project, Ravner.Inventory.Project,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :project_id

    belongs_to :hosting_environment, Ravner.Inventory.HostingEnvironment,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :hosting_environment_id

    belongs_to :network_access, Ravner.Inventory.NetworkAccess,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :network_access_id

    has_many :domains, Ravner.Domains.Domain, destination_attribute: :application_id

    has_many :repositories, Ravner.Inventory.ProjectRepository,
      destination_attribute: :application_id

    has_many :datastores, Ravner.Inventory.Datastore, destination_attribute: :application_id

    has_many :constraints, Ravner.Inventory.ArchitectureConstraint,
      destination_attribute: :application_id

    has_many :application_value_streams, Ravner.Inventory.ApplicationValueStream

    many_to_many :value_streams, Ravner.Inventory.ValueStream,
      through: Ravner.Inventory.ApplicationValueStream,
      source_attribute_on_join_resource: :application_id,
      destination_attribute_on_join_resource: :value_stream_id

    has_many :application_capabilities, Ravner.Inventory.ApplicationCapability

    many_to_many :capabilities, Ravner.Inventory.BusinessCapability,
      through: Ravner.Inventory.ApplicationCapability,
      source_attribute_on_join_resource: :application_id,
      destination_attribute_on_join_resource: :business_capability_id

    has_many :application_external_services, Ravner.Inventory.ApplicationExternalService

    many_to_many :external_services, Ravner.Inventory.ExternalService,
      through: Ravner.Inventory.ApplicationExternalService,
      source_attribute_on_join_resource: :application_id,
      destination_attribute_on_join_resource: :external_service_id
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [
      :name,
      :slug,
      :app_type,
      :lifecycle_state,
      :criticality,
      :description,
      :notes,
      :project_id,
      :hosting_environment_id,
      :network_access_id
    ])
    |> validate_required([:name, :slug, :app_type])
    |> unique_constraint(:slug)
  end
end
