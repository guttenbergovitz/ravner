defmodule Ravner.Repo.Migrations.CreateDomainMetadata do
  use Ecto.Migration

  def change do
    create table(:domain_metadata) do
      add(:domain_id, references(:domains, on_delete: :delete_all), null: false)

      # HTTP snapshot
      add(:http_status, :integer)
      add(:final_url, :string)
      add(:redirect_chain, {:array, :map}, default: [])
      add(:security_headers, :map, default: %{})

      # SSL snapshot
      add(:ssl_issuer, :string)
      add(:ssl_subject, :string)
      add(:ssl_valid_from, :utc_datetime)
      add(:ssl_valid_until, :utc_datetime)
      add(:ssl_days_remaining, :integer)

      # DNS snapshot
      add(:dns_records, {:array, :map}, default: [])
      add(:ip_v4, {:array, :string}, default: [])
      add(:ip_v6, {:array, :string}, default: [])

      # WHOIS / RDAP snapshot
      add(:registrar, :string)
      add(:registrant_org, :string)
      add(:registration_date, :utc_datetime)
      add(:expiration_date, :utc_datetime)
      add(:whois_raw, :text)

      # Infrastructure
      add(:hosting_platform, :string)
      add(:asn_org, :string)
      add(:asn_number, :string)
      add(:server_header, :string)
      add(:tech_stack, {:array, :string}, default: [])

      # Scan provenance
      add(:scanned_at, :utc_datetime)
      add(:scan_duration_ms, :integer)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:domain_metadata, [:domain_id]))
  end
end
