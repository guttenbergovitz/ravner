defmodule Ravner.Inventory.Registrar do
  @moduledoc """
  Ash resource representing a Domain Registrar (e.g. Cloudflare, OVH, Route53, GoDaddy, CSC Global).
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("registrars")
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
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name, :slug, :account_id, :portal_url, :notes])
    end

    update :update do
      primary?(true)
      accept([:name, :slug, :account_id, :portal_url, :notes])
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

    attribute(:account_id, :string)
    attribute(:portal_url, :string)
    attribute(:notes, :string)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    has_many :domains, Ravner.Domains.Domain, destination_attribute: :registrar_id
  end

  identities do
    identity(:unique_name, [:name])
    identity(:unique_slug, [:slug])
  end

  def changeset(registrar, attrs) do
    registrar
    |> cast(attrs, [:name, :slug, :account_id, :portal_url, :notes])
    |> validate_required([:name, :slug])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end
end
