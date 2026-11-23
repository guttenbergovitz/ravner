defmodule Ravner.Inventory.HostingEnvironment do
  @moduledoc """
  Ash resource representing a Hosting Environment / Infrastructure Node (e.g. AWS eu-central-1, Hetzner, Bare Metal).
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("hosting_environments")
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
      accept([:name, :slug, :provider, :environment_tier, :region, :notes])
    end

    update :update do
      primary?(true)
      accept([:name, :slug, :provider, :environment_tier, :region, :notes])
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

    attribute :provider, :string do
      default("aws")
      allow_nil?(false)
    end

    attribute :environment_tier, :string do
      default("production")
      allow_nil?(false)
    end

    attribute(:region, :string)
    attribute(:notes, :string)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    has_many :applications, Ravner.Inventory.Application
    has_many :datastores, Ravner.Inventory.Datastore
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  def changeset(env, attrs) do
    env
    |> cast(attrs, [:name, :slug, :provider, :environment_tier, :region, :notes])
    |> validate_required([:name, :slug, :provider, :environment_tier])
    |> unique_constraint(:slug)
  end
end
