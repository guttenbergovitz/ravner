defmodule Ravner.Inventory.Project do
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field(:name, :string)
    field(:slug, :string)
    field(:display_name, :string)
    field(:description, :string)
    field(:notes, :string)

    belongs_to(:organization, Ravner.Inventory.Organization)
    has_many(:project_roles, Ravner.Inventory.ProjectRole)
    has_many(:domains, Ravner.Domains.Domain)

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug, :display_name, :description, :notes, :organization_id])
    |> validate_required([:name, :slug, :organization_id])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end
end
