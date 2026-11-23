defmodule Ravner.Inventory.Datastore do
  @moduledoc """
  Ash resource representing a Datastore (e.g. PostgreSQL, Redis, MySQL, S3, MongoDB, Elasticsearch).
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("datastores")
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
      accept([:name, :slug, :store_type, :role, :application_id, :hosting_environment_id, :notes])
    end

    update :update do
      primary?(true)
      accept([:name, :slug, :store_type, :role, :application_id, :hosting_environment_id, :notes])
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
    end

    attribute :slug, :string do
      allow_nil?(false)
    end

    attribute :store_type, :string do
      default("postgresql")
      allow_nil?(false)
    end

    attribute :role, :string do
      default("primary_database")
      allow_nil?(false)
    end

    attribute(:application_id, :integer)
    attribute(:hosting_environment_id, :integer)
    attribute(:notes, :string)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :application, Ravner.Inventory.Application,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :application_id

    belongs_to :hosting_environment, Ravner.Inventory.HostingEnvironment,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :hosting_environment_id
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  def changeset(store, attrs) do
    store
    |> cast(attrs, [
      :name,
      :slug,
      :store_type,
      :role,
      :application_id,
      :hosting_environment_id,
      :notes
    ])
    |> validate_required([:name, :slug, :store_type, :role])
    |> unique_constraint(:slug)
  end
end
