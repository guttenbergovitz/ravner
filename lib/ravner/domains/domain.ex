defmodule Ravner.Domains.Domain do
  use Ecto.Schema
  import Ecto.Changeset

  schema "domains" do
    field(:name, :string)
    field(:type, Ecto.Enum, values: [:domain, :subdomain], default: :domain)
    field(:url, :string)

    field(:lifecycle_state, Ecto.Enum,
      values: [:active, :under_review, :deprecated, :decommissioned, :abandoned],
      default: :under_review
    )

    field(:pm_email, :string)
    field(:po_email, :string)
    field(:delivery_organization, :string)

    field(:hosting_platform, :string)
    field(:domain_registrar, :string)
    field(:repository_url, :string)

    belongs_to(:parent_domain, Ravner.Domains.Domain)
    has_many(:subdomains, Ravner.Domains.Domain, foreign_key: :parent_domain_id)
    has_many(:domain_tags, Ravner.Domains.DomainTag)
    has_one(:domain_metadata, Ravner.Domains.DomainMetadata)

    timestamps(type: :utc_datetime)
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
      :repository_url
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
