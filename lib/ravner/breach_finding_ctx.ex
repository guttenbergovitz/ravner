defmodule Ravner.BreachFindingCtx do
  @moduledoc """
  Public API for managing breach findings.
  Handles upsert (insert or update) while preserving existing status.
  Provides status changes with audit logging.
  """

  alias Ravner.{Repo, BreachFinding}

  @spec upsert_finding(map()) :: {:ok, BreachFinding.t()} | {:error, Ecto.Changeset.t()}
  def upsert_finding(attrs) do
    %BreachFinding{}
    |> BreachFinding.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :severity,
           :detail,
           :updated_at,
           :external_id,
           :source
           # status intentionally excluded to preserve existing value
         ]},
      conflict_target: [:domain, :title, :source],
      returning: true
    )
  end

  @spec set_status(integer(), String.t()) :: {:ok, BreachFinding.t()} | {:error, term()}
  def set_status(id, new_status) when new_status in ~w[new resolved false_positive ignored] do
    case Repo.get(BreachFinding, id) do
      nil ->
        {:error, :not_found}

      finding ->
        finding
        |> BreachFinding.changeset(%{status: new_status})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Ravner.ActivityLog.emit(:info, "Breach finding ##{id} marked as #{new_status}")
            {:ok, updated}

          error ->
            error
        end
    end
  end
end
