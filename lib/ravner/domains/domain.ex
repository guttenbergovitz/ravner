defmodule Ravner.Domains.Domain do
  use Ash.Resource,
    domain: Ravner.Domains.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource]

  import Ecto.Changeset

  postgres do
    table "domains"
    repo Ravner.Repo
  end

  paper_trail do
    primary_key_type :integer
    change_tracking_mode :changes_only
    store_action_name? true
    reference_source? false
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [
        :name,
        :type,
        :url,
        :lifecycle_state,
        :pm_email,
        :po_email,
        :delivery_organization,
        :hosting_platform,
        :domain_registrar,
        :repository_url,
        :project_id,
        :brand_id,
        :organization_id,
        :parent_domain_id
      ]
    end

    update :update do
      primary? true
      accept [
        :name,
        :type,
        :url,
        :lifecycle_state,
        :pm_email,
        :po_email,
        :delivery_organization,
        :hosting_platform,
        :domain_registrar,
        :repository_url,
        :project_id,
        :brand_id,
        :organization_id,
        :parent_domain_id
      ]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :name, :string do
      allow_nil? false
    end

    attribute :type, :atom do
      constraints [one_of: [:domain, :subdomain]]
      default :domain
      allow_nil? false
    end

    attribute :url, :string

    attribute :lifecycle_state, :atom do
      constraints [
        one_of: [
          :priority,
          :active,
          :under_review,
          :placeholder,
          :redirect,
          :insecure,
          :deprecated,
          :decommissioned,
          :error,
          :abandoned
        ]
      ]
      default :under_review
    end

    attribute :pm_email, :string
    attribute :po_email, :string
    attribute :delivery_organization, :string
    attribute :hosting_platform, :string
    attribute :domain_registrar, :string
    attribute :repository_url, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :parent_domain, Ravner.Domains.Domain, attribute_type: :integer
    has_many :subdomains, Ravner.Domains.Domain, destination_attribute: :parent_domain_id
    has_many :domain_tags, Ravner.Domains.DomainTag
    has_one :domain_metadata, Ravner.Domains.DomainMetadata
    has_many :dns_records, Ravner.Domains.DnsRecord
    has_many :tech_evidence, Ravner.Domains.TechEvidence
    has_many :discovered_urls, Ravner.Domains.DiscoveredUrl

    belongs_to :project, Ravner.Inventory.Project, attribute_type: :integer
    belongs_to :brand, Ravner.Inventory.Brand, attribute_type: :integer
    belongs_to :organization, Ravner.Inventory.Organization, attribute_type: :integer
  end

  identities do
    identity :unique_name, [:name]
  end

  def changeset(domain, attrs) do
    domain
    |> cast(attrs, [
      :name,
      :type,
      :parent_domain_id,
      :url,
      :lifecycle_state,
      :pm_email,
      :po_email,
      :delivery_organization,
      :hosting_platform,
      :domain_registrar,
      :repository_url,
      :project_id,
      :brand_id,
      :organization_id
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
end
