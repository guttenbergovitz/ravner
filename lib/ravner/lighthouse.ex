defmodule Ravner.Lighthouse do
  @moduledoc """
  PageSpeed scanning via Google Lighthouse CLI.
  """
  import Ecto.Query

  alias Ravner.ActivityLog
  alias Ravner.Domains
  alias Ravner.Lighthouse.LighthouseScan
  alias Ravner.Repo
  alias Ravner.SystemCommand

  # ponytail: lighthouse is heavier than pa11y (~20-45s). 2min timeout is generous.
  @lighthouse_timeout 120_000

  # --- Queries ---

  def latest_scan(domain_id) do
    Repo.one(
      from(s in LighthouseScan,
        where: s.domain_id == ^domain_id and s.status == "completed",
        order_by: [desc: s.completed_at],
        limit: 1
      )
    )
  end

  def running_scan(domain_id) do
    Repo.one(
      from(s in LighthouseScan,
        where: s.domain_id == ^domain_id and s.status in ["pending", "running"],
        order_by: [desc: s.inserted_at],
        limit: 1
      )
    )
  end

  @doc """
  Returns a map of domain_id => performance_score for given domain IDs.
  Only considers the latest completed scan per domain.
  """
  def scores_by_domain_ids(domain_ids) when is_list(domain_ids) do
    if domain_ids == [] do
      %{}
    else
      from(s in LighthouseScan,
        where: s.domain_id in ^domain_ids and s.status == "completed",
        distinct: s.domain_id,
        order_by: [asc: s.domain_id, desc: s.completed_at],
        select: {s.domain_id, s.performance_score}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  # --- Eligibility (same as A11y) ---

  def scannable?(domain) do
    meta = domain.domain_metadata

    meta != nil &&
      meta.http_status == 200 &&
      !external_redirect?(domain.name, meta.final_url)
  end

  defp external_redirect?(_name, nil), do: false

  defp external_redirect?(domain_name, final_url) do
    final_host =
      final_url
      |> URI.parse()
      |> Map.get(:host, "")
      |> to_string()
      |> String.replace_prefix("www.", "")

    domain_root = domain_name |> String.replace_prefix("www.", "")
    final_host != "" && !String.ends_with?(final_host, domain_root)
  end

  # --- Scan execution ---

  def run_scan(domain_id) do
    domain = Domains.get_domain_with_preloads!(domain_id)

    if scannable?(domain) do
      url = effective_url(domain)
      ActivityLog.emit(:step, "Lighthouse — scanning #{domain.name}…")

      scan =
        %LighthouseScan{}
        |> LighthouseScan.changeset(%{
          domain_id: domain_id,
          url: url,
          status: "running",
          started_at: DateTime.utc_now(:second)
        })
        |> Repo.insert!()

      result = execute_lighthouse(url)
      finalize_scan(scan, result, domain.name)
    else
      {:error, :not_scannable}
    end
  end

  defp effective_url(domain) do
    case domain.domain_metadata && domain.domain_metadata.final_url do
      url when is_binary(url) and url != "" -> url
      _ -> "https://#{domain.name}"
    end
  end

  defp execute_lighthouse(url) do
    args = [
      url,
      "--output",
      "json",
      "--output-path",
      "stdout",
      "--chrome-flags=--headless --no-sandbox --disable-gpu",
      "--only-categories=performance,accessibility,best-practices,seo",
      "--quiet"
    ]

    case SystemCommand.run_with_timeout("lighthouse", args, @lighthouse_timeout) do
      {:error, :timeout} ->
        {:error, "Lighthouse timed out after #{div(@lighthouse_timeout, 1000)}s"}

      {:error, reason} ->
        {:error, inspect(reason)}

      {output, 0} ->
        parse_lighthouse_output(output)

      {output, _code} ->
        # Lighthouse may exit non-zero but still produce JSON (e.g. page has errors)
        case parse_lighthouse_output(output) do
          {:ok, _} = ok -> ok
          _ -> {:error, String.slice(output || "", 0, 2000)}
        end
    end
  end

  defp parse_lighthouse_output(output) do
    # Lighthouse sometimes prefixes JSON with log lines — find the JSON start
    json_start = find_json_start(output)

    case Jason.decode(json_start) do
      {:ok, lhr} ->
        categories = lhr["categories"] || %{}

        scores = %{
          performance: score_to_int(categories["performance"]),
          accessibility: score_to_int(categories["accessibility"]),
          best_practices: score_to_int(categories["best-practices"]),
          seo: score_to_int(categories["seo"])
        }

        audits = lhr["audits"] || %{}

        metrics = %{
          fcp_ms: metric_value(audits, "first-contentful-paint"),
          lcp_ms: metric_value(audits, "largest-contentful-paint"),
          tbt_ms: metric_value(audits, "total-blocking-time"),
          cls: metric_float(audits, "cumulative-layout-shift"),
          speed_index_ms: metric_value(audits, "speed-index")
        }

        {:ok, %{scores: scores, metrics: metrics, lhr: lhr}}

      {:error, _} ->
        {:error, "Failed to parse Lighthouse JSON output"}
    end
  end

  defp find_json_start(output) do
    # LHR JSON starts with { — skip any preceding log lines
    case :binary.match(output, "{") do
      {pos, _} -> binary_part(output, pos, byte_size(output) - pos)
      :nomatch -> output
    end
  end

  defp score_to_int(%{"score" => score}) when is_number(score), do: round(score * 100)
  defp score_to_int(_), do: nil

  defp metric_value(audits, key) do
    case audits[key] do
      %{"numericValue" => v} when is_number(v) -> round(v)
      _ -> nil
    end
  end

  defp metric_float(audits, key) do
    case audits[key] do
      %{"numericValue" => v} when is_number(v) -> Float.round(v * 1.0, 3)
      _ -> nil
    end
  end

  defp finalize_scan(scan, {:ok, %{scores: scores, metrics: metrics, lhr: lhr}}, domain_name) do
    # Store condensed version — full LHR can be huge, keep only categories + audits summary
    condensed = %{
      "categories" => lhr["categories"],
      "audits" => condense_audits(lhr["audits"])
    }

    {:ok, updated} =
      scan
      |> LighthouseScan.changeset(%{
        status: "completed",
        completed_at: DateTime.utc_now(:second),
        performance_score: scores.performance,
        accessibility_score: scores.accessibility,
        best_practices_score: scores.best_practices,
        seo_score: scores.seo,
        fcp_ms: metrics.fcp_ms,
        lcp_ms: metrics.lcp_ms,
        tbt_ms: metrics.tbt_ms,
        cls: metrics.cls,
        speed_index_ms: metrics.speed_index_ms,
        results_raw: condensed
      })
      |> Repo.update()

    Domains.upsert_domain_metadata(scan.domain_id, %{
      last_lighthouse_scan_at: DateTime.utc_now(:second)
    })

    ActivityLog.emit(
      :done,
      "Lighthouse done — #{domain_name}: perf #{scores.performance}, seo #{scores.seo}"
    )

    broadcast(scan.domain_id, updated)
    {:ok, updated}
  end

  defp finalize_scan(scan, {:error, reason}, domain_name) do
    {:ok, updated} =
      scan
      |> LighthouseScan.changeset(%{
        status: "failed",
        completed_at: DateTime.utc_now(:second),
        error_message: reason
      })
      |> Repo.update()

    ActivityLog.emit(
      :error,
      "Lighthouse failed — #{domain_name}: #{String.slice(reason, 0, 100)}"
    )

    broadcast(scan.domain_id, updated)
    {:error, updated}
  end

  # Keep only audits that have a score < 1 (opportunities/diagnostics) to save space
  defp condense_audits(nil), do: %{}

  defp condense_audits(audits) do
    audits
    |> Enum.filter(fn {_k, v} ->
      is_map(v) && Map.has_key?(v, "score") &&
        (v["score"] == nil || v["score"] < 1)
    end)
    |> Enum.map(fn {k, v} ->
      {k, Map.take(v, ["id", "title", "description", "score", "displayValue", "numericValue"])}
    end)
    |> Map.new()
  end

  defp broadcast(domain_id, scan) do
    Phoenix.PubSub.broadcast(
      Ravner.PubSub,
      "lighthouse_scan:domain:#{domain_id}",
      {:lighthouse_scan_completed, scan}
    )
  end
end
