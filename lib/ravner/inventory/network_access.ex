defmodule Ravner.Inventory.NetworkAccess do
  @moduledoc """
  Ash resource representing a Network Access & Ingress boundary (e.g. Public Internet vs Corporate WireGuard / Zero Trust).
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("network_accesses")
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
      accept([:name, :slug, :access_level, :vpn_gateway_name, :notes])
    end

    update :update do
      primary?(true)
      accept([:name, :slug, :access_level, :vpn_gateway_name, :notes])
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

    attribute :access_level, :string do
      default("public_internet")
      allow_nil?(false)
    end

    attribute(:vpn_gateway_name, :string)
    attribute(:notes, :string)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    has_many :applications, Ravner.Inventory.Application
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  def changeset(network, attrs) do
    network
    |> cast(attrs, [:name, :slug, :access_level, :vpn_gateway_name, :notes])
    |> validate_required([:name, :slug, :access_level])
    |> unique_constraint(:slug)
  end
end
