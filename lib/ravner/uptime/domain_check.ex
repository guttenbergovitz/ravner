defmodule Ravner.Uptime.DomainCheck do
  @moduledoc """
  Ecto schema representing a monitored URL endpoint check for a domain.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          url: String.t() | nil,
          label: String.t() | nil,
          check_interval_minutes: integer(),
          failure_threshold: integer(),
          enabled: boolean(),
          is_up: boolean() | nil,
          last_checked_at: DateTime.t() | nil,
          domain_id: integer() | nil,
          domain: Ravner.Domains.Domain.t() | term(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "domain_checks" do
    field :url, :string
    field :label, :string
    field :check_interval_minutes, :integer, default: 5
    field :failure_threshold, :integer, default: 2
    field :enabled, :boolean, default: true
    field :is_up, :boolean
    field :last_checked_at, :utc_datetime

    belongs_to :domain, Ravner.Domains.Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(check, attrs) do
    check
    |> cast(attrs, [
      :url,
      :label,
      :check_interval_minutes,
      :failure_threshold,
      :enabled,
      :domain_id
    ])
    |> validate_required([:url, :domain_id, :check_interval_minutes])
    |> validate_number(:check_interval_minutes, greater_than_or_equal_to: 1)
    |> validate_url()
  end

  defp validate_url(changeset) do
    case get_field(changeset, :url) do
      nil ->
        changeset

      url ->
        uri = URI.parse(url)

        if uri.scheme in ["http", "https"] && uri.host && uri.host != "" do
          changeset
        else
          add_error(changeset, :url, "must be a valid HTTP(S) URL")
        end
    end
  end
end
