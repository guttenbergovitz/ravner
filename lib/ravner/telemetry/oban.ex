defmodule Ravner.Telemetry.Oban do
  @moduledoc """
  Structured telemetry handler for Oban job lifecycle events.
  """

  require Logger

  @events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ]

  def attach do
    :telemetry.attach_many("ravner-oban", @events, &__MODULE__.handle_event/4, nil)
  end

  def handle_event([:oban, :job, :start], measurements, metadata, _config) do
    Logger.debug("Oban job started", measurements: measurements, metadata: job_metadata(metadata))
  end

  def handle_event([:oban, :job, :stop], measurements, metadata, _config) do
    Logger.info("Oban job completed",
      measurements: measurements,
      metadata: job_metadata(metadata)
    )
  end

  def handle_event([:oban, :job, :exception], measurements, metadata, _config) do
    Logger.error("Oban job failed", measurements: measurements, metadata: job_metadata(metadata))
  end

  defp job_metadata(%{job: job} = metadata) do
    Map.take(metadata, [:queue, :worker, :state, :attempt, :max_attempts])
    |> Map.put(:job_id, Map.get(job, :id))
  end

  defp job_metadata(metadata), do: metadata
end
