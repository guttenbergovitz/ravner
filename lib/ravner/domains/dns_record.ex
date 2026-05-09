defmodule Ravner.Domains.DnsRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "domain_dns_records" do
    belongs_to(:domain, Ravner.Domains.Domain)
    field(:type, :string)
    field(:value, :string)
    field(:ttl, :integer)

    timestamps(type: :utc_datetime)
  end

  def changeset(dns_record, attrs) do
    dns_record
    |> cast(attrs, [:domain_id, :type, :value, :ttl])
    |> validate_required([:domain_id, :type, :value])
  end
end
