defmodule Ravner.Inventory.ApplicationExternalService do
  @moduledoc """
  Join resource connecting Application to ExternalService (e.g. Gadget.dev, Fivetran, Stripe).
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  policies do
    policy action_type(:read) do
      authorize_if({Ravner.Accounts.ScopeReadCheck, []})
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(actor_attribute_equals(:role, :editor))
    end
  end

  postgres do
    table("application_external_services")
    repo(Ravner.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:application_id, :external_service_id, :integration_type])
    end
  end

  attributes do
    attribute :integration_type, :string do
      default("api")
    end

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :application, Ravner.Inventory.Application,
      primary_key?: true,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :external_service, Ravner.Inventory.ExternalService,
      primary_key?: true,
      allow_nil?: false,
      attribute_type: :integer
  end
end
