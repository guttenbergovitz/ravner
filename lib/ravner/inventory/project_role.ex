defmodule Ravner.Inventory.ProjectRole do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "project_roles" do
    field(:role, :string)
    field(:notes, :string)

    belongs_to(:project, Ravner.Inventory.Project)
    belongs_to(:person, Ravner.Inventory.Person)

    timestamps(type: :utc_datetime)
  end

  def changeset(pr, attrs) do
    pr
    |> cast(attrs, [:role, :notes, :project_id, :person_id])
    |> validate_required([:role, :project_id, :person_id])
    |> unique_constraint([:project_id, :person_id],
      name: :project_roles_project_id_person_id_index
    )
  end
end
