defmodule Ravner.Domains.DiscoveredUrl do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "domain_discovered_urls" do
    belongs_to(:domain, Ravner.Domains.Domain)
    field(:url, :string)
    field(:status, :integer)
    field(:content_type, :string)
    field(:source, :string)

    timestamps(type: :utc_datetime)
  end

  def changeset(discovered_url, attrs) do
    discovered_url
    |> cast(attrs, [:domain_id, :url, :status, :content_type, :source])
    |> validate_required([:domain_id, :url])
  end
end
