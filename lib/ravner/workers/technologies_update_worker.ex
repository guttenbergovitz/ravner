defmodule Ravner.Workers.TechnologiesUpdateWorker do
  @moduledoc """
  Downloads the latest Wappalyzer technologies database used by
  `Ravner.Scans.TechFingerprint` for native technology fingerprinting.

  Scheduled daily via `Oban.Plugins.Cron` and enqueued on boot when the
  database file is missing (fresh containers, first deploy).
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3_600]

  require Logger

  alias Ravner.Scans.TechFingerprint

  @default_url "https://raw.githubusercontent.com/rverton/webanalyze/master/technologies.json"
  @default_min_technologies 500
  @receive_timeout 30_000

  @impl Oban.Worker
  def perform(_job) do
    url = Application.get_env(:ravner, :wappalyzer_technologies_url, @default_url)
    path = TechFingerprint.storage_path()

    case download(url, path) do
      {:ok, count} ->
        Ravner.ActivityLog.emit(
          :done,
          "Wappalyzer technologies updated — #{count} fingerprints"
        )

        :ok

      {:error, reason} ->
        Logger.warning("Technologies update failed: #{inspect(reason)}")
        Ravner.ActivityLog.emit(:error, "Wappalyzer technologies update failed: #{reason}")
        {:error, to_string(reason)}
    end
  end

  defp download(url, path) do
    req_opts =
      [url: url, receive_timeout: @receive_timeout, retry: false, decode_body: false]
      |> Keyword.merge(Application.get_env(:ravner, :wappalyzer_req_opts, []))

    with {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) <-
           Req.get(req_opts),
         {:ok, count} <- validate(body) do
      store(path, body)
      {:ok, count}
    else
      {:ok, %Req.Response{status: status}} -> {:error, "upstream returned status #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate(body) do
    min = Application.get_env(:ravner, :wappalyzer_min_technologies, @default_min_technologies)

    case Jason.decode(body) do
      {:ok, %{"technologies" => techs}} when map_size(techs) >= min ->
        {:ok, map_size(techs)}

      {:ok, techs} when map_size(techs) >= min ->
        {:ok, map_size(techs)}

      {:ok, _} ->
        {:error, "technologies file looks truncated"}

      {:error, _} ->
        {:error, "invalid JSON"}
    end
  end

  defp store(path, body) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    tmp = Path.join(dir, ".technologies-#{System.unique_integer([:positive])}.tmp")
    File.write!(tmp, body)
    File.rename!(tmp, path)
  end
end
