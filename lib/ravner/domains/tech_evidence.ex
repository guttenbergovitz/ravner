defmodule Ravner.Domains.TechEvidence do
  @moduledoc """
  Ecto schema representing technology evidence discovered for a domain.
  """
  use Ash.Resource,
    domain: Ravner.Domains.AshDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("domain_tech_evidence")
    repo(Ravner.Repo)
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
    defaults([:read, :destroy, :create, :update])
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
    end

    attribute(:version, :string)
    attribute(:source, :string)
    attribute(:confidence, :integer)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :domain, Ravner.Domains.Domain, attribute_type: :integer
  end

  def changeset(tech_evidence, attrs) do
    tech_evidence
    |> cast(attrs, [:domain_id, :name, :version, :source, :confidence])
    |> validate_required([:domain_id, :name])
  end
end
