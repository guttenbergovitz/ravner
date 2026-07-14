defmodule Ravner.A11y do
  @moduledoc """
  Accessibility scanning via pa11y CLI.
  """
  import Ecto.Query

  require Logger

  alias Ravner.A11y.A11yScan
  alias Ravner.ActivityLog
  alias Ravner.Domains
  alias Ravner.Repo
  alias Ravner.SystemCommand

  @pa11y_timeout 90_000
  @standard "WCAG2AA"

  # --- Queries ---

  def latest_scan(domain_id) do
    Repo.one(
      from(s in A11yScan,
        where: s.domain_id == ^domain_id and s.status == "completed",
        order_by: [desc: s.completed_at],
        limit: 1
      )
    )
  end

  @doc """
  Returns a map of domain_id => violations_count for all given domain IDs.
  Only considers the latest completed scan per domain.
  Returns nil for domains with no completed scan.
  """
  def violations_by_domain_ids(domain_ids) when is_list(domain_ids) do
    if domain_ids == [] do
      %{}
    else
      # Lateral join: latest completed scan per domain
      from(s in A11yScan,
        where: s.domain_id in ^domain_ids and s.status == "completed",
        distinct: s.domain_id,
        order_by: [asc: s.domain_id, desc: s.completed_at],
        select: {s.domain_id, s.violations_count}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  def running_scan(domain_id) do
    Repo.one(
      from(s in A11yScan,
        where: s.domain_id == ^domain_id and s.status in ["pending", "running"],
        order_by: [desc: s.inserted_at],
        limit: 1
      )
    )
  end

  # --- Eligibility ---

  @doc """
  Returns true if the domain has HTTP 200 and no external redirect.
  Requires domain_metadata to be preloaded.
  """
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

  @doc """
  Runs pa11y against the domain's effective URL.
  Called from the Oban worker or inline for manual triggers.
  """
  def run_scan(domain_id) do
    domain = Domains.get_domain_with_preloads!(domain_id)

    if scannable?(domain) do
      url = effective_url(domain)
      ActivityLog.emit(:step, "A11y — scanning #{domain.name}…")

      scan =
        %A11yScan{}
        |> A11yScan.changeset(%{
          domain_id: domain_id,
          url: url,
          standard: @standard,
          status: "running",
          started_at: DateTime.utc_now(:second)
        })
        |> Repo.insert!()

      result = execute_pa11y(url)
      finalize_scan(scan, result)
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

  defp execute_pa11y(url) do
    # ponytail: config file passes --no-sandbox to Chromium for Docker.
    # On bare metal this is harmless (sandbox just stays enabled).
    config_path = Application.app_dir(:ravner, "priv/pa11y.json")

    args = [
      "--reporter",
      "json",
      "--standard",
      @standard,
      "--timeout",
      "60000",
      "--config",
      config_path,
      url
    ]

    case SystemCommand.run_with_timeout("pa11y", args, @pa11y_timeout) do
      {:error, :timeout} ->
        {:error, "pa11y timed out after #{div(@pa11y_timeout, 1000)}s"}

      {:error, reason} ->
        {:error, inspect(reason)}

      {output, 0} ->
        # exit 0 = no issues found — but verify pa11y actually ran
        # pa11y with --reporter json outputs nothing on 0 issues,
        # but outputs error text if Chromium failed to launch
        output = String.trim(output)

        cond do
          output == "" ->
            # Legit zero issues — pa11y ran successfully, found nothing
            {:ok, []}

          String.starts_with?(output, "[") ->
            # JSON array — shouldn't happen on exit 0 but handle gracefully
            case Jason.decode(output) do
              {:ok, issues} when is_list(issues) -> {:ok, issues}
              _ -> {:error, "Failed to parse pa11y output"}
            end

          true ->
            # Non-empty, non-JSON output = error message from pa11y/chromium
            {:error, "pa11y error: #{String.slice(output, 0, 500)}"}
        end

      {output, 2} ->
        # exit 2 = issues found, output is JSON array
        case Jason.decode(output) do
          {:ok, issues} when is_list(issues) -> {:ok, issues}
          _ -> {:error, "Failed to parse pa11y output"}
        end

      {output, _code} ->
        # exit 1 or other = pa11y error
        {:error, String.slice(output || "", 0, 2000)}
    end
  end

  defp finalize_scan(scan, {:ok, issues}) do
    violations = Enum.count(issues, &(&1["type"] == "error"))
    warnings = Enum.count(issues, &(&1["type"] == "warning"))

    {:ok, updated} =
      scan
      |> A11yScan.changeset(%{
        status: "completed",
        completed_at: DateTime.utc_now(:second),
        violations_count: violations,
        warnings_count: warnings,
        results_raw: %{"issues" => issues}
      })
      |> Repo.update()

    Domains.upsert_domain_metadata(scan.domain_id, %{
      last_a11y_scan_at: DateTime.utc_now(:second)
    })

    ActivityLog.emit(:done, "A11y done — #{violations} violations, #{warnings} warnings")
    broadcast(scan.domain_id, updated)
    {:ok, updated}
  end

  defp finalize_scan(scan, {:error, reason}) do
    {:ok, updated} =
      scan
      |> A11yScan.changeset(%{
        status: "failed",
        completed_at: DateTime.utc_now(:second),
        error_message: reason
      })
      |> Repo.update()

    ActivityLog.emit(:error, "A11y failed: #{String.slice(reason, 0, 100)}")
    broadcast(scan.domain_id, updated)
    {:error, updated}
  end

  defp broadcast(domain_id, scan) do
    Phoenix.PubSub.broadcast(
      Ravner.PubSub,
      "a11y_scan:domain:#{domain_id}",
      {:a11y_scan_completed, scan}
    )
  end
end
