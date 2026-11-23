defmodule Ravner.Domains.DomainMetadata do
  @moduledoc """
  Ecto schema representing aggregated metadata for a domain.
  """
  use Ash.Resource,
    domain: Ravner.Domains.AshDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  postgres do
    table("domain_metadata")
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
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
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
        :js_assets,
        :forms,
        :deep_scan_errors,
        :scanned_at,
        :scan_duration_ms,
        :http_scanned_at,
        :dns_scanned_at,
        :subdomains_scanned_at,
        :rdap_scanned_at,
        :deep_tech_scanned_at,
        :last_security_scan_at,
        :ssl_scanned_at,
        :open_ports,
        :scan_interval_days,
        :heartbeat_interval_minutes,
        :ssl_check_interval_days,
        :tech_discovery_interval_days,
        :http_scan_interval_days,
        :dns_scan_interval_days,
        :is_up,
        :last_heartbeat_at,
        :a11y_scan_interval_days,
        :last_a11y_scan_at,
        :lighthouse_scan_interval_days,
        :last_lighthouse_scan_at,
        :risk_score,
        :risk_grade,
        :risk_deductions,
        :risk_drivers
      ])
    end

    update :update do
      primary?(true)

      accept([
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
        :js_assets,
        :forms,
        :deep_scan_errors,
        :scanned_at,
        :scan_duration_ms,
        :http_scanned_at,
        :dns_scanned_at,
        :subdomains_scanned_at,
        :rdap_scanned_at,
        :deep_tech_scanned_at,
        :last_security_scan_at,
        :ssl_scanned_at,
        :open_ports,
        :scan_interval_days,
        :heartbeat_interval_minutes,
        :ssl_check_interval_days,
        :tech_discovery_interval_days,
        :http_scan_interval_days,
        :dns_scan_interval_days,
        :is_up,
        :last_heartbeat_at,
        :a11y_scan_interval_days,
        :last_a11y_scan_at,
        :lighthouse_scan_interval_days,
        :last_lighthouse_scan_at,
        :risk_score,
        :risk_grade,
        :risk_deductions,
        :risk_drivers
      ])
    end
  end

  attributes do
    integer_primary_key(:id)

    # HTTP snapshot
    attribute(:http_status, :integer)
    attribute(:final_url, :string)

    attribute :redirect_chain, {:array, :map} do
      default([])
    end

    attribute :security_headers, :map do
      default(%{})
    end

    # SSL snapshot
    attribute(:ssl_issuer, :string)
    attribute(:ssl_subject, :string)
    attribute(:ssl_valid_from, :utc_datetime)
    attribute(:ssl_valid_until, :utc_datetime)
    attribute(:ssl_days_remaining, :integer)

    # DNS snapshot
    attribute :ip_v4, {:array, :string} do
      default([])
    end

    attribute :ip_v6, {:array, :string} do
      default([])
    end

    # WHOIS / RDAP snapshot
    attribute(:registrar, :string)
    attribute(:registrant_org, :string)
    attribute(:registration_date, :utc_datetime)
    attribute(:expiration_date, :utc_datetime)
    attribute(:whois_raw, :string)

    attribute :contacts, :map do
      default(%{})
    end

    # Infrastructure
    attribute(:hosting_platform, :string)
    attribute(:asn_org, :string)
    attribute(:asn_number, :string)
    attribute(:server_header, :string)

    attribute :tech_stack, {:array, :string} do
      default([])
    end

    attribute :js_assets, {:array, :string} do
      default([])
    end

    attribute :forms, {:array, :map} do
      default([])
    end

    attribute :deep_scan_errors, {:array, :string} do
      default([])
    end

    # Scan provenance
    attribute(:scanned_at, :utc_datetime)
    attribute(:scan_duration_ms, :integer)
    attribute(:http_scanned_at, :utc_datetime)
    attribute(:dns_scanned_at, :utc_datetime)
    attribute(:subdomains_scanned_at, :utc_datetime)
    attribute(:rdap_scanned_at, :utc_datetime)
    attribute(:deep_tech_scanned_at, :utc_datetime)
    attribute(:last_security_scan_at, :utc_datetime)
    attribute(:ssl_scanned_at, :utc_datetime)

    # Security scan results
    attribute :open_ports, {:array, :integer} do
      default([])
    end

    # Scheduling & Heartbeats
    attribute(:scan_interval_days, :integer)
    attribute(:heartbeat_interval_minutes, :integer)
    attribute(:ssl_check_interval_days, :integer)
    attribute(:tech_discovery_interval_days, :integer)
    attribute(:http_scan_interval_days, :integer)
    attribute(:dns_scan_interval_days, :integer)
    attribute(:is_up, :boolean)
    attribute(:last_heartbeat_at, :utc_datetime)
    attribute(:a11y_scan_interval_days, :integer)
    attribute(:last_a11y_scan_at, :utc_datetime)
    attribute(:lighthouse_scan_interval_days, :integer)
    attribute(:last_lighthouse_scan_at, :utc_datetime)

    # Cyber Risk Scoring
    attribute(:risk_score, :integer)

    attribute :risk_grade, :string do
      default("N/A")
    end

    attribute :risk_deductions, :map do
      default(%{})
    end

    attribute :risk_drivers, {:array, :string} do
      default([])
    end

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :domain, Ravner.Domains.Domain, attribute_type: :integer
  end

  identities do
    identity(:unique_domain, [:domain_id])
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
      :js_assets,
      :forms,
      :deep_scan_errors,
      :scanned_at,
      :scan_duration_ms,
      :http_scanned_at,
      :dns_scanned_at,
      :subdomains_scanned_at,
      :rdap_scanned_at,
      :deep_tech_scanned_at,
      :last_security_scan_at,
      :open_ports,
      :scan_interval_days,
      :heartbeat_interval_minutes,
      :ssl_check_interval_days,
      :tech_discovery_interval_days,
      :http_scan_interval_days,
      :dns_scan_interval_days,
      :is_up,
      :last_heartbeat_at,
      :a11y_scan_interval_days,
      :last_a11y_scan_at,
      :lighthouse_scan_interval_days,
      :last_lighthouse_scan_at,
      :risk_score,
      :risk_grade,
      :risk_deductions,
      :risk_drivers
    ])
    |> validate_required([:domain_id])
    |> foreign_key_constraint(:domain_id)
    |> unique_constraint(:domain_id)
  end
end
