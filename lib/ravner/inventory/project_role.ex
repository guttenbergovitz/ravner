defmodule Ravner.Inventory.ProjectRole do
  @moduledoc """
  Ash resource representing a role within a project.
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("project_roles")
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
      authorize_if({Ravner.Accounts.ScopeCheck, permission: :manage_project_role})
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:role, :notes, :project_id, :person_id])
    end

    update :update do
      primary?(true)
      accept([:role, :notes, :project_id, :person_id])
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :role, :string do
      allow_nil?(false)
    end

    attribute(:notes, :string)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :project, Ravner.Inventory.Project, attribute_type: :integer
    belongs_to :person, Ravner.Inventory.Person, attribute_type: :integer
  end

  identities do
    identity(:unique_project_person, [:project_id, :person_id])
  end

  # Keep Ecto changeset for UI compatibility during migration Phase 2-4
  def changeset(pr, attrs) do
    pr
    |> cast(attrs, [:role, :notes, :project_id, :person_id])
    |> validate_required([:role, :project_id, :person_id])
    |> unique_constraint([:project_id, :person_id],
      name: :project_roles_project_id_person_id_index
    )
  end
end
