defmodule Ravner.Inventory.Brand do
  @moduledoc """
  Ash resource representing a brand.
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  json_api do
    type("brand")

    routes do
      base("/brands")
      get(:read)
      index(:read)
      post(:create)
      patch(:update)
      delete(:destroy)
    end
  end

  postgres do
    table("brands")
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

    policy action_type(:create) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end

    policy action_type(:update) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(actor_attribute_equals(:role, :editor))
    end

    policy action_type(:destroy) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name, :slug, :display_name, :notes, :brand_manager_id])
    end

    update :update do
      primary?(true)
      accept([:name, :slug, :display_name, :notes, :brand_manager_id])
    end

    update :assign_brand_manager do
      accept([:brand_manager_id])
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

    attribute(:display_name, :string, public?: true)
    attribute(:notes, :string, public?: true)
    attribute(:brand_manager_id, :integer, public?: true)

    create_timestamp(:inserted_at, type: :utc_datetime, public?: true)
    update_timestamp(:updated_at, type: :utc_datetime, public?: true)
  end

  relationships do
    has_many :organizations, Ravner.Inventory.Organization

    belongs_to :brand_manager, Ravner.Inventory.Person,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :brand_manager_id
  end

  identities do
    identity(:unique_name, [:name])
    identity(:unique_slug, [:slug])
  end

  # Keep Ecto changeset for UI compatibility during migration Phase 2-4
  def changeset(brand, attrs) do
    brand
    |> cast(attrs, [:name, :slug, :display_name, :notes, :brand_manager_id])
    |> validate_required([:name, :slug])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:brand_manager_id)
  end
end
