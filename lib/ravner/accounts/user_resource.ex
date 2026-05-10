defmodule Ravner.Accounts.UserResource do
  @moduledoc """
  Ash governance resource mapped to the users table.

  The phx.gen.auth-facing `Ravner.Accounts.User` Ecto schema remains the public
  auth struct so password virtual fields and token queries keep their generated
  semantics.
  """
  use Ash.Resource,
    domain: Ravner.Accounts.AshDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("users")
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
      accept([:email, :hashed_password, :confirmed_at, :role, :name, :active])
    end

    update :admin_update do
      primary?(true)
      accept([:name, :role, :active])
    end

    update :confirm do
      accept([:confirmed_at])
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :email, :ci_string do
      allow_nil?(false)
    end

    attribute(:hashed_password, :string, sensitive?: true)
    attribute(:confirmed_at, :utc_datetime)

    attribute :role, :atom do
      constraints(one_of: [:admin, :editor, :viewer])
      default(:viewer)
      allow_nil?(false)
    end

    attribute(:name, :string)

    attribute :active, :boolean do
      default(true)
      allow_nil?(false)
    end

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    has_many :tokens, Ravner.Accounts.UserTokenResource, destination_attribute: :user_id
    has_many :invites, Ravner.Accounts.UserInviteResource, destination_attribute: :invited_by_id
  end

  identities do
    identity(:unique_email, [:email])
  end
end
