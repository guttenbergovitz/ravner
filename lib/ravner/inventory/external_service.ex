defmodule Ravner.Inventory.ExternalService do
  @moduledoc """
  Ash resource representing an External Managed Service or Platform (e.g. Gadget.dev, Fivetran, Stripe, Auth0).
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("external_services")
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
      accept([:name, :slug, :service_type, :url, :notes])
    end

    update :update do
      primary?(true)
      accept([:name, :slug, :service_type, :url, :notes])
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

    attribute :service_type, :string do
      default("saas")
      allow_nil?(false)
    end

    attribute(:url, :string)
    attribute(:notes, :string)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    has_many :application_external_services, Ravner.Inventory.ApplicationExternalService

    many_to_many :applications, Ravner.Inventory.Application,
      through: Ravner.Inventory.ApplicationExternalService,
      source_attribute_on_join_resource: :external_service_id,
      destination_attribute_on_join_resource: :application_id
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  def changeset(service, attrs) do
    service
    |> cast(attrs, [:name, :slug, :service_type, :url, :notes])
    |> validate_required([:name, :slug])
    |> unique_constraint(:slug)
  end
end
