defmodule Ravner.Inventory.ApplicationCapability do
  @moduledoc """
  Join resource connecting Application to BusinessCapability.
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
    table("application_capabilities")
    repo(Ravner.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:application_id, :business_capability_id])
    end
  end

  attributes do
    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :application, Ravner.Inventory.Application,
      primary_key?: true,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :business_capability, Ravner.Inventory.BusinessCapability,
      primary_key?: true,
      allow_nil?: false,
      attribute_type: :integer
  end
end
