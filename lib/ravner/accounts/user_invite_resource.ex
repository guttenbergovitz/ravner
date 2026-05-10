defmodule Ravner.Accounts.UserInviteResource do
  @moduledoc """
  Ash governance resource mapped to user invites.
  """
  use Ash.Resource,
    domain: Ravner.Accounts.AshDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("user_invites")
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
      accept([:token, :email, :role, :name, :invited_by_id, :expires_at])
    end

    update :accept do
      accept([:accepted_at])
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :token, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :email, :string do
      allow_nil?(false)
    end

    attribute :role, :atom do
      constraints(one_of: [:admin, :editor, :viewer])
      default(:viewer)
      allow_nil?(false)
    end

    attribute(:name, :string)
    attribute(:accepted_at, :utc_datetime)

    attribute :expires_at, :utc_datetime do
      allow_nil?(false)
    end

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :invited_by, Ravner.Accounts.UserResource, attribute_type: :integer
  end

  identities do
    identity(:unique_token, [:token])
  end
end
