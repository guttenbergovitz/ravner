defmodule Ravner.ScanConfig do
  @moduledoc """
  Global scan configuration singleton.
  Controls which nuclei severities and template tags are active.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ravner.Repo

  @valid_severities ~w(critical high medium low info)
  @valid_tags ~w(cves misconfig exposure panel network dns file token default-login)

  schema "scan_config" do
    field :nuclei_severities, {:array, :string}, default: ["critical", "high", "medium"]
    field :nuclei_tags, {:array, :string}, default: []
    field :nuclei_exclude_tags, {:array, :string}, default: []
    field :security_scanner, :string, default: "nuclei"

    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:nuclei_severities, :nuclei_tags, :nuclei_exclude_tags, :security_scanner])
    |> validate_inclusion(:security_scanner, ["nuclei", "lonkero"])
    |> validate_values_in(:nuclei_severities, @valid_severities)
    |> validate_values_in(:nuclei_tags, @valid_tags)
    |> validate_values_in(:nuclei_exclude_tags, @valid_tags)
  end

  @doc "Returns the singleton config row (creates default if missing)."
  def get do
    case Repo.one(__MODULE__) do
      nil ->
        %__MODULE__{}
        |> changeset(%{})
        |> Repo.insert!()

      config ->
        config
    end
  end

  @doc "Updates the singleton config."
  def update(attrs) do
    get()
    |> changeset(attrs)
    |> Repo.update()
  end

  def valid_severities, do: @valid_severities
  def valid_tags, do: @valid_tags

  defp validate_values_in(changeset, field, allowed) do
    validate_change(changeset, field, fn _, values ->
      invalid = Enum.reject(values, &(&1 in allowed))

      if invalid == [],
        do: [],
        else: [{field, "contains invalid values: #{Enum.join(invalid, ", ")}"}]
    end)
  end
end
