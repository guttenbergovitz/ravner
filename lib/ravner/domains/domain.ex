defmodule Ravner.Domains.Domain do
  @moduledoc """
  Ecto schema representing a discovered domain or subdomain.
  """

  # Lifecycle state classifications
  @scannable_states [:priority, :active, :under_review]
  @operational_states [
    :priority,
    :active,
    :under_review,
    :placeholder,
    :redirect_internal,
    :redirect_external
  ]
  @archived_states [:deprecated, :decommissioned, :abandoned]
  @redirect_states [:redirect_internal, :redirect_external]

  use Ash.Resource,
    domain: Ravner.Domains.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  json_api do
    type("domain")

    routes do
      base("/domains")
      get(:read)
      index(:read)
      post(:create)
      patch(:update)
      delete(:destroy)
    end
  end

  postgres do
    table("domains")
    repo(Ravner.Repo)
  end

  paper_trail do
    primary_key_type(:integer)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    reference_source?(false)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      validate(present(:name))
      validate(match(:name, ~r/^[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z0-9][-a-zA-Z0-9.]*$/))

      accept([
        :name,
        :type,
        :url,
        :lifecycle_state,
        :technical_status,
        :redirect_target_url,
        :redirect_target_domain_id,
        :pm_email,
        :po_email,
        :delivery_organization,
        :hosting_platform,
        :domain_registrar,
        :repository_url,
        :project_id,
        :brand_id,
        :organization_id,
        :parent_domain_id,
        :application_id,
        :registrar_id
      ])
    end

    update :update do
      primary?(true)

      accept([
        :name,
        :type,
        :url,
        :lifecycle_state,
        :technical_status,
        :redirect_target_url,
        :redirect_target_domain_id,
        :pm_email,
        :po_email,
        :delivery_organization,
        :hosting_platform,
        :domain_registrar,
        :repository_url,
        :project_id,
        :brand_id,
        :organization_id,
        :parent_domain_id,
        :application_id,
        :registrar_id
      ])
    end

    update :set_lifecycle do
      accept([:lifecycle_state])
    end

    update :assign_project do
      accept([:project_id, :brand_id, :organization_id])
    end

    update :assign_brand do
      accept([:brand_id, :project_id, :organization_id])
    end

    update :assign_organization do
      accept([:organization_id, :project_id, :brand_id])
    end

    update :assign_contacts do
      accept([:pm_email, :po_email])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if({Ravner.Accounts.ScopeReadCheck, []})
    end

    policy action(:destroy) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end

    policy action_type([:create, :update]) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(actor_attribute_equals(:role, :editor))
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :type, :atom do
      constraints(one_of: [:domain, :subdomain])
      default(:domain)
      allow_nil?(false)
      public?(true)
    end

    attribute(:url, :string, public?: true)

    attribute :lifecycle_state, :atom do
      constraints(
        one_of: [
          :priority,
          :active,
          :under_review,
          :placeholder,
          :redirect_internal,
          :redirect_external,
          :deprecated,
          :decommissioned,
          :abandoned
        ]
      )

      default(:under_review)
      public?(true)
    end

    # For redirect domains: where they redirect to
    attribute(:redirect_target_url, :string, public?: true)

    attribute :technical_status, :atom do
      constraints(one_of: [:unknown, :reachable, :redirect, :insecure, :error])
      default(:unknown)
      allow_nil?(false)
      public?(true)
    end

    attribute(:pm_email, :string, public?: true)
    attribute(:po_email, :string, public?: true)
    attribute(:delivery_organization, :string, public?: true)
    attribute(:hosting_platform, :string, public?: true)
    attribute(:domain_registrar, :string, public?: true)
    attribute(:repository_url, :string, public?: true)
    attribute(:application_id, :integer, public?: true)
    attribute(:registrar_id, :integer, public?: true)

    create_timestamp(:inserted_at, type: :utc_datetime, public?: true)
    update_timestamp(:updated_at, type: :utc_datetime, public?: true)
  end

  relationships do
    belongs_to :parent_domain, Ravner.Domains.Domain, attribute_type: :integer
    belongs_to :redirect_target_domain, Ravner.Domains.Domain, attribute_type: :integer
    has_many :subdomains, Ravner.Domains.Domain, destination_attribute: :parent_domain_id

    has_many :redirecting_domains, Ravner.Domains.Domain,
      destination_attribute: :redirect_target_domain_id

    has_many :domain_tags, Ravner.Domains.DomainTag
    has_one :domain_metadata, Ravner.Domains.DomainMetadata
    has_many :dns_records, Ravner.Domains.DnsRecord
    has_many :tech_evidence, Ravner.Domains.TechEvidence
    has_many :discovered_urls, Ravner.Domains.DiscoveredUrl

    has_many :repositories, Ravner.Inventory.ProjectRepository, destination_attribute: :domain_id

    belongs_to :project, Ravner.Inventory.Project, attribute_type: :integer
    belongs_to :brand, Ravner.Inventory.Brand, attribute_type: :integer
    belongs_to :organization, Ravner.Inventory.Organization, attribute_type: :integer

    belongs_to :application, Ravner.Inventory.Application,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :application_id

    belongs_to :registrar, Ravner.Inventory.Registrar,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :registrar_id
  end

  identities do
    identity(:unique_name, [:name])
  end

  def changeset(domain, attrs) do
    domain
    |> cast(attrs, [
      :name,
      :type,
      :parent_domain_id,
      :url,
      :lifecycle_state,
      :technical_status,
      :redirect_target_url,
      :redirect_target_domain_id,
      :pm_email,
      :po_email,
      :delivery_organization,
      :hosting_platform,
      :domain_registrar,
      :repository_url,
      :project_id,
      :brand_id,
      :organization_id,
      :application_id,
      :registrar_id
    ])
    |> validate_required([:name, :type])
    |> validate_format(:name, ~r/^[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z0-9][-a-zA-Z0-9.]*$/,
      message: "must be a valid domain name"
    )
    |> unique_constraint(:name)
    |> foreign_key_constraint(:parent_domain_id)
    |> maybe_link_parent()
  end

  defp maybe_link_parent(changeset) do
    case {get_field(changeset, :type), get_field(changeset, :parent_domain_id)} do
      {:subdomain, nil} ->
        name = get_field(changeset, :name) || ""

        case extract_parent(name) do
          nil -> changeset
          parent_name -> put_change(changeset, :parent_name_hint, parent_name)
        end

      _ ->
        changeset
    end
  end

  defp extract_parent(name) do
    parts = String.split(name, ".")

    if length(parts) > 2 do
      parts |> Enum.drop(1) |> Enum.join(".")
    else
      nil
    end
  end

  # ─── Lifecycle State Helpers ─────────────────────────────────────────────────

  @doc "States eligible for scanning (priority, active, under_review)."
  def scannable_states, do: @scannable_states

  @doc "States shown by default in listings (excludes archived)."
  def operational_states, do: @operational_states

  @doc "Archived states hidden by default (deprecated, decommissioned, abandoned)."
  def archived_states, do: @archived_states

  @doc "Check if domain is eligible for scanning."
  def scannable?(%{lifecycle_state: state}), do: state in @scannable_states
  def scannable?(state) when is_atom(state), do: state in @scannable_states

  @doc "Check if domain is operational (shown by default in listings)."
  def operational?(%{lifecycle_state: state}), do: state in @operational_states
  def operational?(state) when is_atom(state), do: state in @operational_states

  @doc "Check if domain is archived (hidden by default)."
  def archived?(%{lifecycle_state: state}), do: state in @archived_states
  def archived?(state) when is_atom(state), do: state in @archived_states

  @doc "Check if domain is a placeholder (excluded from non-placeholder views)."
  def placeholder?(%{lifecycle_state: :placeholder}), do: true
  def placeholder?(%{lifecycle_state: _}), do: false
  def placeholder?(:placeholder), do: true
  def placeholder?(_), do: false

  @doc "Redirect states (internal and external redirects)."
  def redirect_states, do: @redirect_states

  @doc "Check if domain is a redirect (internal or external)."
  def redirect?(%{lifecycle_state: state}), do: state in @redirect_states
  def redirect?(state) when is_atom(state), do: state in @redirect_states
  def redirect?(_), do: false

  @doc "Check if domain is an internal redirect."
  def redirect_internal?(%{lifecycle_state: :redirect_internal}), do: true
  def redirect_internal?(_), do: false

  @doc "Check if domain is an external redirect."
  def redirect_external?(%{lifecycle_state: :redirect_external}), do: true
  def redirect_external?(_), do: false

  @doc "States that should hide scoring/security sections."
  def hide_scoring?(%{lifecycle_state: state}) when state in [:placeholder | @redirect_states],
    do: true

  def hide_scoring?(_), do: false
end
