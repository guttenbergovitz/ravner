defmodule Ravner.Accounts.UserInviteResource do
  @moduledoc """
  Ash governance resource mapped to user invites.
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
    sensitive_attributes(:ignore)
    reference_source?(false)
  end

  postgres do
    table("user_invites")
    repo(Ravner.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(relates_to_actor_via(:invited_by))
    end

    policy action(:create) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if({Ravner.Accounts.ScopeCheck, permission: :delegate_invite})
    end

    policy action(:accept) do
      authorize_if(always())
    end

    policy action_type([:update, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :token,
        :email,
        :role,
        :name,
        :invited_by_id,
        :target_brand_id,
        :target_organization_id,
        :target_project_id,
        :supervisor_id,
        :expires_at
      ])
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
    attribute(:target_brand_id, :integer)
    attribute(:target_organization_id, :integer)
    attribute(:target_project_id, :integer)
    attribute(:supervisor_id, :integer)
    attribute(:accepted_at, :utc_datetime)

    attribute :expires_at, :utc_datetime do
      allow_nil?(false)
      sensitive?(true)
    end

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :invited_by, Ravner.Accounts.UserResource, attribute_type: :integer
    belongs_to :supervisor, Ravner.Accounts.UserResource, attribute_type: :integer
  end

  identities do
    identity(:unique_token, [:token])
  end
end
