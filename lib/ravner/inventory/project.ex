defmodule Ravner.Inventory.Project do
  @moduledoc """
  Ash resource representing a project.
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  json_api do
    type("project")

    routes do
      base("/projects")
      get(:read)
      index(:read)
      post(:create)
      patch(:update)
      delete(:destroy)
    end
  end

  postgres do
    table("projects")
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
      authorize_if({Ravner.Accounts.ScopeCheck, permission: :manage_project})
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      validate(present([:name, :slug, :organization_id]))
      validate(match(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/))

      accept([
        :name,
        :slug,
        :display_name,
        :description,
        :notes,
        :project_type,
        :organization_id,
        :project_manager_id,
        :product_owner_id
      ])
    end

    update :update do
      primary?(true)

      accept([
        :name,
        :slug,
        :display_name,
        :description,
        :notes,
        :project_type,
        :organization_id,
        :project_manager_id,
        :product_owner_id
      ])
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :slug, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute(:display_name, :string, public?: true)
    attribute(:description, :string, public?: true)
    attribute(:notes, :string, public?: true)

    attribute :project_type, :string do
      default("customer_facing")
      public?(true)
    end

    attribute(:organization_id, :integer, public?: true)
    attribute(:project_manager_id, :integer, public?: true)
    attribute(:product_owner_id, :integer, public?: true)

    create_timestamp(:inserted_at, type: :utc_datetime, public?: true)
    update_timestamp(:updated_at, type: :utc_datetime, public?: true)
  end

  relationships do
    belongs_to :organization, Ravner.Inventory.Organization, attribute_type: :integer
    belongs_to :project_manager, Ravner.Inventory.Person, attribute_type: :integer
    belongs_to :product_owner, Ravner.Inventory.Person, attribute_type: :integer
    has_many :project_roles, Ravner.Inventory.ProjectRole
    has_many :project_repositories, Ravner.Inventory.ProjectRepository
    has_many :applications, Ravner.Inventory.Application
    # Omit domain cross-context relationship in Ash for now
  end

  identities do
    identity(:unique_name, [:name])
    identity(:unique_slug, [:slug])
  end

  # Keep Ecto changeset for UI compatibility during migration Phase 2-4
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :name,
      :slug,
      :display_name,
      :description,
      :notes,
      :project_type,
      :organization_id,
      :project_manager_id,
      :product_owner_id
    ])
    |> validate_required([:name, :slug, :organization_id])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:project_manager_id)
    |> foreign_key_constraint(:product_owner_id)
  end
end
