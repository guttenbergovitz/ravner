defmodule Ravner.Inventory.ValueStream do
  @moduledoc """
  Ash resource representing a Business Value Stream (e.g. Order to Cash, Product Catalog Enrichment).
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("value_streams")
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
      accept([:name, :slug, :description, :stage, :criticality, :brand_id, :business_owner_id])
    end

    update :update do
      primary?(true)
      accept([:name, :slug, :description, :stage, :criticality, :brand_id, :business_owner_id])
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

    attribute(:description, :string)

    attribute :stage, :string do
      default("active")
    end

    attribute :criticality, :string do
      default("operational")
    end

    attribute(:brand_id, :integer)
    attribute(:business_owner_id, :integer)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :brand, Ravner.Inventory.Brand,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :brand_id

    belongs_to :business_owner, Ravner.Inventory.Person,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :business_owner_id

    has_many :application_value_streams, Ravner.Inventory.ApplicationValueStream

    many_to_many :applications, Ravner.Inventory.Application,
      through: Ravner.Inventory.ApplicationValueStream,
      source_attribute_on_join_resource: :value_stream_id,
      destination_attribute_on_join_resource: :application_id
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  def changeset(stream, attrs) do
    stream
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :stage,
      :criticality,
      :brand_id,
      :business_owner_id
    ])
    |> validate_required([:name, :slug])
    |> unique_constraint(:slug)
  end
end
