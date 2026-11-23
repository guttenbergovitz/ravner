defmodule Ravner.Inventory.Organization do
  @moduledoc """
  Ash resource representing an organization.
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  json_api do
    type("organization")

    routes do
      base("/organizations")
      get(:read)
      index(:read)
      post(:create)
      patch(:update)
      delete(:destroy)
    end
  end

  postgres do
    table("organizations")
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

    policy action_type(:create) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(actor_attribute_equals(:role, :editor))
      authorize_if({Ravner.Accounts.ScopeCheck, permission: :manage_organization})
    end

    policy action_type([:update, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(actor_attribute_equals(:role, :editor))
      authorize_if({Ravner.Accounts.ScopeCheck, permission: :manage_organization})
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      validate(present([:name, :slug, :type]))
      validate(match(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/))
      accept([:name, :slug, :display_name, :type, :country, :notes, :brand_id, :manager_id])
    end

    update :update do
      primary?(true)
      accept([:name, :slug, :display_name, :type, :country, :notes, :brand_id, :manager_id])
    end

    update :assign_manager do
      accept([:manager_id])
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

    attribute :type, :atom do
      constraints(one_of: [:internal, :client, :contractor, :partner])
      default(:internal)
      allow_nil?(false)
      public?(true)
    end

    attribute(:country, :string, public?: true)
    attribute(:notes, :string, public?: true)
    attribute(:brand_id, :integer, public?: true)
    attribute(:manager_id, :integer, public?: true)

    create_timestamp(:inserted_at, type: :utc_datetime, public?: true)
    update_timestamp(:updated_at, type: :utc_datetime, public?: true)
  end

  relationships do
    belongs_to :brand, Ravner.Inventory.Brand, attribute_type: :integer
    has_many :projects, Ravner.Inventory.Project
    has_many :people, Ravner.Inventory.Person

    belongs_to :manager, Ravner.Inventory.Person,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :manager_id
  end

  identities do
    identity(:unique_name, [:name])
    identity(:unique_slug, [:slug])
  end

  # Keep Ecto changeset for UI compatibility during migration Phase 2-4
  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :slug, :display_name, :type, :country, :notes, :brand_id, :manager_id])
    |> validate_required([:name, :slug, :type])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:manager_id)
    |> generate_slug()
  end

  defp generate_slug(changeset) do
    slug = get_field(changeset, :slug)

    if slug && slug != "" do
      changeset
    else
      name = get_field(changeset, :name)

      if name do
        auto =
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        put_change(changeset, :slug, auto)
      else
        changeset
      end
    end
  end
end
