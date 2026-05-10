defmodule Ravner.Accounts.UserTokenResource do
  @moduledoc """
  Ash resource for persisted auth tokens.
  """
  use Ash.Resource,
    domain: Ravner.Accounts.AshDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("users_tokens")
    repo(Ravner.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:user_id, :token, :context, :sent_to, :authenticated_at])
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :token, :binary do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :context, :string do
      allow_nil?(false)
    end

    attribute(:sent_to, :string)
    attribute(:authenticated_at, :utc_datetime)

    create_timestamp(:inserted_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :user, Ravner.Accounts.UserResource, attribute_type: :integer, allow_nil?: false
  end

  identities do
    identity(:unique_context_token, [:context, :token])
  end
end
