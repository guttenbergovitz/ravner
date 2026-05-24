defmodule Ravner.Inventory.Project do
  @moduledoc """
  Ash resource representing a project.
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("projects")
    repo(Ravner.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
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
      accept([:name, :slug, :display_name, :description, :notes, :organization_id])
    end

    update :update do
      primary?(true)
      accept([:name, :slug, :display_name, :description, :notes, :organization_id])
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

    attribute(:display_name, :string)
    attribute(:description, :string)
    attribute(:notes, :string)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :organization, Ravner.Inventory.Organization, attribute_type: :integer
    has_many :project_roles, Ravner.Inventory.ProjectRole
    has_many :project_repositories, Ravner.Inventory.ProjectRepository
    # Omit domain cross-context relationship in Ash for now
  end

  identities do
    identity(:unique_name, [:name])
    identity(:unique_slug, [:slug])
  end

  # Keep Ecto changeset for UI compatibility during migration Phase 2-4
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug, :display_name, :description, :notes, :organization_id])
    |> validate_required([:name, :slug, :organization_id])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end
end
