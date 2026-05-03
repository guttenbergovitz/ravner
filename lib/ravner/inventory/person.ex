defmodule Ravner.Inventory.Person do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "people" do
    field(:first_name, :string)
    field(:last_name, :string)
    field(:title, :string)
    field(:email, :string)
    field(:phone, :string)
    field(:mobile, :string)
    field(:default_role, :string)
    field(:notes, :string)

    belongs_to(:organization, Ravner.Inventory.Organization)
    has_many(:project_roles, Ravner.Inventory.ProjectRole)

    timestamps(type: :utc_datetime)
  end

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
      :organization_id
    ])
    |> validate_required([:first_name, :last_name])
    |> unique_constraint(:email)
  end
end
