defmodule Ravner.Inventory.ArchitectureConstraint do
  @moduledoc """
  Ash resource representing an Architecture Constraint as Policy-as-Code (e.g. EAA, NIS2, DORA, GDPR, VPN-only).
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("architecture_constraints")
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

      accept([
        :name,
        :category,
        :rule_type,
        :enforcement_level,
        :compliance_status,
        :parameters,
        :application_id
      ])
    end

    update :update do
      primary?(true)

      accept([
        :name,
        :category,
        :rule_type,
        :enforcement_level,
        :compliance_status,
        :parameters,
        :application_id,
        :last_evaluated_at
      ])
    end

    update :evaluate do
      accept([:compliance_status, :last_evaluated_at])
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
    end

    attribute :category, :string do
      default("perimeter")
      allow_nil?(false)
    end

    attribute :rule_type, :string do
      allow_nil?(false)
    end

    attribute :enforcement_level, :string do
      default("mandatory")
    end

    attribute :compliance_status, :string do
      default("unknown")
    end

    attribute :parameters, :map do
      default(%{})
    end

    attribute(:last_evaluated_at, :utc_datetime)
    attribute(:application_id, :integer)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :application, Ravner.Inventory.Application,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :application_id
  end

  def changeset(constraint, attrs) do
    constraint
    |> cast(attrs, [
      :name,
      :category,
      :rule_type,
      :enforcement_level,
      :compliance_status,
      :parameters,
      :application_id,
      :last_evaluated_at
    ])
    |> validate_required([:name, :category, :rule_type])
  end
end
