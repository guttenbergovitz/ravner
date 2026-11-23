defmodule Ravner.Inventory.Person do
  @moduledoc """
  Ash resource representing a person.
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("people")
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
      authorize_if({Ravner.Accounts.ScopeCheck, permission: :manage_person})
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :first_name,
        :last_name,
        :title,
        :email,
        :phone,
        :mobile,
        :default_role,
        :notes,
        :organization_id,
        :user_id
      ])
    end

    update :update do
      primary?(true)

      accept([
        :first_name,
        :last_name,
        :title,
        :email,
        :phone,
        :mobile,
        :default_role,
        :notes,
        :organization_id,
        :user_id
      ])
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :first_name, :string do
      allow_nil?(false)
    end

    attribute :last_name, :string do
      allow_nil?(false)
    end

    attribute(:title, :string)
    attribute(:email, :string)
    attribute(:phone, :string)
    attribute(:mobile, :string)
    attribute(:default_role, :string)
    attribute(:notes, :string)
    attribute(:user_id, :integer)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :organization, Ravner.Inventory.Organization, attribute_type: :integer
    belongs_to :user, Ravner.Accounts.UserResource, attribute_type: :integer
    has_many :project_roles, Ravner.Inventory.ProjectRole
  end

  identities do
    identity(:unique_email, [:email])
  end

  # Keep Ecto changeset for UI compatibility during migration Phase 2-4
  def changeset(person, attrs) do
    person
    |> cast(attrs, [
      :first_name,
      :last_name,
      :title,
      :email,
      :phone,
      :mobile,
      :default_role,
      :notes,
      :organization_id,
      :user_id
    ])
    |> validate_required([:first_name, :last_name])
    |> unique_constraint(:email)
    |> unique_constraint(:user_id)
  end
end
