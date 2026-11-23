defmodule Ravner.Scans.CveCacheEntry do
  @moduledoc """
  Persisted cache for OSV.dev vulnerability lookups.

  Stores vulnerability findings keyed by `{ecosystem, package, version}`
  with an expiration timestamp, preventing redundant external API calls
  across domains and server restarts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "cve_cache" do
    field :ecosystem, :string
    field :package, :string
    field :version, :string
    field :findings, {:array, :map}, default: []
    field :queried_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:ecosystem, :package, :version, :findings, :queried_at, :expires_at])
    |> validate_required([:ecosystem, :package, :version, :queried_at, :expires_at])
    |> unique_constraint([:ecosystem, :package, :version])
  end
end
