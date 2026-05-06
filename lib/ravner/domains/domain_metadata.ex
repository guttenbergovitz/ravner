defmodule Ravner.Domains.DomainMetadata do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "domain_metadata" do
    belongs_to(:domain, Ravner.Domains.Domain)

    # HTTP snapshot
    field(:http_status, :integer)
    field(:final_url, :string)
    field(:redirect_chain, {:array, :map}, default: [])
    field(:security_headers, :map, default: %{})

    # SSL snapshot
    field(:ssl_issuer, :string)
    field(:ssl_subject, :string)
    field(:ssl_valid_from, :utc_datetime)
    field(:ssl_valid_until, :utc_datetime)
    field(:ssl_days_remaining, :integer)

    # DNS snapshot
    field(:dns_records, {:array, :map}, default: [])
    field(:ip_v4, {:array, :string}, default: [])
    field(:ip_v6, {:array, :string}, default: [])

    # WHOIS / RDAP snapshot
    field(:registrar, :string)
    field(:registrant_org, :string)
    field(:registration_date, :utc_datetime)
    field(:expiration_date, :utc_datetime)
    field(:whois_raw, :string)
    field(:contacts, :map, default: %{})

    # Infrastructure
    field(:hosting_platform, :string)
    field(:asn_org, :string)
    field(:asn_number, :string)
    field(:server_header, :string)
    field(:tech_stack, {:array, :string}, default: [])

    # Scan provenance
    field(:scanned_at, :utc_datetime)
    field(:scan_duration_ms, :integer)
    field(:http_scanned_at, :utc_datetime)
    field(:dns_scanned_at, :utc_datetime)
    field(:subdomains_scanned_at, :utc_datetime)
    field(:rdap_scanned_at, :utc_datetime)
    field(:last_security_scan_at, :utc_datetime)

    # Security scan results
    field(:open_ports, {:array, :integer}, default: [])

    timestamps(type: :utc_datetime)
  end

  def changeset(metadata, attrs) do
    metadata
    |> cast(attrs, [
      :domain_id,
      :http_status,
      :final_url,
      :redirect_chain,
      :security_headers,
      :ssl_issuer,
      :ssl_subject,
      :ssl_valid_from,
      :ssl_valid_until,
      :ssl_days_remaining,
      :dns_records,
      :ip_v4,
      :ip_v6,
      :registrar,
      :registrant_org,
      :registration_date,
      :expiration_date,
      :whois_raw,
      :contacts,
      :hosting_platform,
      :asn_org,
      :asn_number,
      :server_header,
      :tech_stack,
      :scanned_at,
      :scan_duration_ms,
      :http_scanned_at,
      :dns_scanned_at,
      :subdomains_scanned_at,
      :rdap_scanned_at,
      :last_security_scan_at,
      :open_ports
    ])
    |> validate_required([:domain_id])
    |> foreign_key_constraint(:domain_id)
    |> unique_constraint(:domain_id)
  end
end
