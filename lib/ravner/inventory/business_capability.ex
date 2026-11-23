defmodule Ravner.Inventory.BusinessCapability do
  @moduledoc """
  Ash resource representing a Business Capability (e.g. Payment Processing, PIM, Content Management).
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("business_capabilities")
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
      accept([:name, :slug, :category, :description])
    end

    update :update do
      primary?(true)
      accept([:name, :slug, :category, :description])
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

    attribute(:category, :string)
    attribute(:description, :string)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    has_many :application_capabilities, Ravner.Inventory.ApplicationCapability

    many_to_many :applications, Ravner.Inventory.Application,
      through: Ravner.Inventory.ApplicationCapability,
      source_attribute_on_join_resource: :business_capability_id,
      destination_attribute_on_join_resource: :application_id
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  def changeset(cap, attrs) do
    cap
    |> cast(attrs, [:name, :slug, :category, :description])
    |> validate_required([:name, :slug])
    |> unique_constraint(:slug)
  end
end
