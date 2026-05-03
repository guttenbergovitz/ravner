defmodule Ravner.Inventory.ProjectRepository do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds ~w(website portal ecommerce cms landing app api library tool documentation config other)

  schema "project_repositories" do
    field(:url, :string)
    field(:kind, :string, default: "website")
    field(:main_language, :string)
    field(:technology, :string)
    field(:notes, :string)

    belongs_to(:project, Ravner.Inventory.Project)

    timestamps(type: :utc_datetime)
  end

  def changeset(repo, attrs) do
    repo
    |> cast(attrs, [:url, :kind, :main_language, :technology, :notes, :project_id])
    |> validate_required([:url, :kind, :project_id])
    |> validate_inclusion(:kind, @kinds)
  end

  def kinds, do: @kinds
end
