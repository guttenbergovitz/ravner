defmodule Ravner.Inventory.ProjectRepository do
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer

  import Ecto.Changeset

  @kinds ~w(website portal ecommerce cms landing app api library tool documentation config other)

  postgres do
    table "project_repositories"
    repo Ravner.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:url, :kind, :main_language, :technology, :notes, :project_id]
    end

    update :update do
      primary? true
      accept [:url, :kind, :main_language, :technology, :notes, :project_id]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :url, :string do
      allow_nil? false
    end

    attribute :kind, :string do
      default "website"
      allow_nil? false
    end

    attribute :main_language, :string
    attribute :technology, :string
    attribute :notes, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :project, Ravner.Inventory.Project, attribute_type: :integer
  end

  # Keep Ecto changeset for UI compatibility during migration Phase 2-4
  def changeset(repo, attrs) do
    repo
    |> cast(attrs, [:url, :kind, :main_language, :technology, :notes, :project_id])
    |> validate_required([:url, :kind, :project_id])
    |> validate_inclusion(:kind, @kinds)
  end

  def kinds, do: @kinds
end
