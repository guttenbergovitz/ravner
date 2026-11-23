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
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  paper_trail do
    primary_key_type(:integer)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    reference_source?(false)
  end

  postgres do
    table("users")
    repo(Ravner.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(actor_attribute_equals(:role, :editor))
      authorize_if(relates_to_actor_via(:supervisor))
    end

    policy action(:confirm) do
      authorize_if(always())
    end

    policy action(:admin_update) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if({Ravner.Accounts.ScopeCheck, permission: :manage_user})
    end

    policy action_type([:create, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:email, :hashed_password, :confirmed_at, :role, :name, :active, :supervisor_id])
    end

    update :admin_update do
      primary?(true)
      accept([:name, :role, :active, :supervisor_id])
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

    attribute :confirmed_at, :utc_datetime do
      sensitive?(true)
    end

    attribute :role, :atom do
      constraints(
        one_of: [
          :admin,
          :editor,
          :viewer,
          :brand_manager,
          :organization_manager,
          :product_owner,
          :delivery_head,
          :pm_supervisor,
          :project_manager
        ]
      )

      default(:viewer)
      allow_nil?(false)
    end

    attribute(:name, :string)

    attribute :active, :boolean do
      default(true)
      allow_nil?(false)
    end

    attribute(:supervisor_id, :integer)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :supervisor, Ravner.Accounts.UserResource, attribute_type: :integer

    has_many :supervised_users, Ravner.Accounts.UserResource,
      destination_attribute: :supervisor_id

    has_many :tokens, Ravner.Accounts.UserTokenResource, destination_attribute: :user_id
    has_many :invites, Ravner.Accounts.UserInviteResource, destination_attribute: :invited_by_id
    has_one :person, Ravner.Inventory.Person, destination_attribute: :user_id
  end

  identities do
    identity(:unique_email, [:email])
  end
end
