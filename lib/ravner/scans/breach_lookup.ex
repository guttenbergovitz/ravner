defmodule Ravner.Scans.BreachLookup do
  @moduledoc """
  Dark Web & Infostealer Intelligence scanner using Hudson Rock's public OSINT API.

  Provides zero-credential, real-time intelligence on compromised employee
  and customer identities harvested by infostealer malware (RedLine, Vidar,
  Lumma, Raccoon, etc.) circulating in dark web markets and Telegram channels.

  Evaluates recency ("heat status") to distinguish active, ongoing credential
  exposure from dormant historical data.
  """

  require Logger

  alias Ravner.Scans.HttpRetry

  @endpoint "https://cavalier.hudsonrock.com/api/json/v2/osint-tools/search-by-domain"
  @timeout_ms 8_000
  @max_retries 2

  @doc """
  Queries Hudson Rock for infostealer compromise records for a given domain.

  Returns `{:ok, stats_map, findings_list}` or `{:error, reason}`.
  """
  @spec lookup(String.t(), keyword()) :: {:ok, map(), [map()]} | {:error, String.t()}
  def lookup(domain_name, opts \\ []) when is_binary(domain_name) do
    clean_domain = clean_host(domain_name)
    req_fun = Keyword.get(opts, :req_fun, &default_fetch/2)

    case req_fun.(clean_domain, opts) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        process_response(clean_domain, body)

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, json} when is_map(json) ->
            process_response(clean_domain, json)

          _ ->
            {:ok,
             %{
               total: 0,
               employees: 0,
               users: 0,
               heat: :clean,
               heat_label: "Clean — No records detected"
             }, []}
        end

      {:ok, %{status: 404, body: body}} ->
        # 404 from Hudson Rock means domain has no records in database (clean)
        # but only if we get a valid JSON response body, not an error page
        if is_map(body) or (is_binary(body) and body =~ ~r/^\s*\{/) or body in ["", nil] do
          {:ok,
           %{
             total: 0,
             employees: 0,
             users: 0,
             heat: :clean,
             heat_label: "Clean — No records detected"
           }, []}
        else
          Logger.warning(
            "Hudson Rock 404 with unexpected body for #{clean_domain}: #{inspect(String.slice(to_string(body), 0, 100))}"
          )

          {:error, "Hudson Rock API returned 404 with unexpected response"}
        end

      {:ok, %{status: status}} ->
        Logger.warning("Hudson Rock returned unexpected status #{status} for #{clean_domain}")
        {:error, "Hudson Rock returned HTTP #{status}"}

      {:error, reason} ->
        Logger.warning("Hudson Rock request failed for #{clean_domain}: #{inspect(reason)}")
        {:error, "Failed to connect to breach intelligence: #{inspect(reason)}"}
    end
  rescue
    e in [Req.TransportError, Mint.TransportError, RuntimeError, ArgumentError, Jason.DecodeError] ->
      Logger.warning("Unexpected error during breach lookup for #{domain_name}: #{inspect(e)}")
      {:error, "Unexpected error: #{inspect(e)}"}
  end

  @doc """
  Calculates the heat (recency) status for a compromise timestamp.

  Returns `{heat_atom, label_string, days_ago}`:
  - `:hot` — compromise detected within last 30 days (Active threat)
  - `:recent` — compromise detected 31–180 days ago (Recent exposure)
  - `:historical` — compromise detected > 180 days ago (Archival/Dormant)
  - `:clean` — no compromise records
  """
  @spec calculate_heat(String.t() | nil, String.t() | nil, integer()) ::
          {:hot | :recent | :historical | :clean, String.t(), integer() | nil}
  def calculate_heat(last_employee_date, last_user_date, employees_count) do
    target_date_str = last_employee_date || last_user_date

    cond do
      employees_count == 0 and is_nil(target_date_str) ->
        {:clean, "Clean — No infostealer records detected", nil}

      is_nil(target_date_str) and employees_count > 0 ->
        {:historical, "Historical — Compromises present with unrecorded date", nil}

      is_binary(target_date_str) ->
        case DateTime.from_iso8601(target_date_str) do
          {:ok, datetime, _offset} ->
            diff_days = max(0, DateTime.diff(DateTime.utc_now(), datetime, :day))

            cond do
              diff_days <= 30 ->
                {:hot, "🔥 Hot & Active — compromised #{diff_days} days ago", diff_days}

              diff_days <= 180 ->
                {:recent, "⚠️ Recent — compromised #{diff_days} days ago", diff_days}

              true ->
                {:historical, "📦 Historical — last seen #{diff_days} days ago", diff_days}
            end

          _ ->
            {:historical, "Historical — #{target_date_str}", nil}
        end

      true ->
        {:clean, "Clean", nil}
    end
  end

  # ─── Internal helpers ──────────────────────────────────────────────────────

  defp default_fetch(domain, _opts) do
    url = "#{@endpoint}?domain=#{domain}"

    HttpRetry.with_retry(
      fn ->
        Req.get(url,
          headers: [
            {"user-agent",
             "Mozilla/5.0 (compatible; RavnerSecurityPosture/1.0; +https://github.com)"},
            {"accept", "application/json"}
          ],
          receive_timeout: @timeout_ms,
          connect_options: [timeout: 5_000]
        )
      end,
      max_retries: @max_retries
    )
  end

  defp process_response(domain, body) do
    employees = body["employees"] || 0
    users = body["users"] || 0
    total = body["total"] || 0
    third_parties = body["third_parties"] || 0

    last_employee = body["last_employee_compromised"]
    last_user = body["last_user_compromised"]

    {heat, heat_label, days_ago} = calculate_heat(last_employee, last_user, employees)

    # Extract top stealer malware families (e.g. RedLine, Raccoon, Vidar)
    stealer_families =
      case body["stealerFamilies"] do
        map when is_map(map) ->
          map
          |> Map.drop(["total", "UNKNOWN", "Generic Stealer"])
          |> Enum.sort_by(&elem(&1, 1), :desc)
          |> Enum.take(5)
          |> Enum.map(&elem(&1, 0))

        _ ->
          []
      end

    # Extract corporate targeted URLs
    targeted_urls =
      case get_in(body, ["data", "employees_urls"]) do
        urls when is_list(urls) ->
          urls
          |> Enum.map(fn item ->
            item["url"] || item[:url]
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.take(6)

        _ ->
          []
      end

    stats = %{
      domain: domain,
      total: total,
      employees: employees,
      users: users,
      third_parties: third_parties,
      last_employee_compromised: last_employee,
      last_user_compromised: last_user,
      heat: heat,
      heat_label: heat_label,
      days_ago: days_ago,
      stealer_families: stealer_families,
      targeted_urls: targeted_urls
    }

    findings = build_findings(domain, stats)

    {:ok, stats, findings}
  end

  defp build_findings(domain, stats) do
    cond do
      stats.employees > 0 ->
        severity =
          case stats.heat do
            :hot -> "critical"
            :recent -> "high"
            :historical -> "medium"
            _ -> "medium"
          end

        heat_prefix =
          case stats.heat do
            :hot -> "🔥 [ACTIVE / HOT]"
            :recent -> "⚠️ [RECENT]"
            :historical -> "📦 [HISTORICAL]"
            _ -> ""
          end

        description = build_description(stats)

        [
          %{
            severity: severity,
            title:
              "#{heat_prefix} #{stats.employees} corporate employee credentials leaked in stealer logs",
            target: domain,
            detail: %{
              "service" => "Dark Web Infostealers",
              "summary" =>
                "#{stats.employees} corporate employee credentials found in infostealer logs",
              "heat" => to_string(stats.heat),
              "heat_label" => stats.heat_label,
              "days_ago" => stats.days_ago,
              "last_compromised" =>
                stats.last_employee_compromised || stats.last_user_compromised,
              "employees_count" => stats.employees,
              "users_count" => stats.users,
              "stealer_families" => stats.stealer_families,
              "targeted_urls" => stats.targeted_urls,
              "description" => description,
              "references" => [
                "https://cavalier.hudsonrock.com",
                "https://www.cisa.gov/news-events/alerts/2023/10/18/infostealer-threats"
              ],
              "source" => "hudson_rock"
            }
          }
        ]

      stats.users > 50 ->
        # If no employees but customer user accounts leaked in significant numbers
        [
          %{
            severity: "medium",
            title: "#{stats.users} customer accounts exposed in stealer logs",
            target: domain,
            detail: %{
              "service" => "Dark Web Infostealers (Clients)",
              "summary" => "#{stats.users} customer accounts exposed in stealer logs",
              "heat" => to_string(stats.heat),
              "heat_label" => stats.heat_label,
              "users_count" => stats.users,
              "references" => ["https://cavalier.hudsonrock.com"],
              "source" => "hudson_rock"
            }
          }
        ]

      true ->
        []
    end
  end

  defp build_description(stats) do
    parts = [
      "Detected #{stats.employees} corporate employee accounts associated with #{stats.domain} compromised by infostealer malware.",
      "Status: #{stats.heat_label}.",
      if(stats.stealer_families != [],
        do: "Identified malware families: #{Enum.join(stats.stealer_families, ", ")}.",
        else: nil
      ),
      if(stats.targeted_urls != [],
        do: "Compromised corporate portals: #{Enum.join(stats.targeted_urls, ", ")}.",
        else: nil
      ),
      "Remediation: Immediately revoke active session tokens, force corporate password reset, and enforce hardware-backed 2FA (WebAuthn/FIDO2) on sensitive internal endpoints."
    ]

    parts |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")
  end

  defp clean_host(host) do
    host = String.trim(host)

    cond do
      String.starts_with?(host, "http://") or String.starts_with?(host, "https://") ->
        uri = URI.parse(host)
        uri.host || host

      String.contains?(host, "/") ->
        host |> String.split("/") |> List.first()

      String.contains?(host, ":") ->
        host |> String.split(":") |> List.first()

      true ->
        host
    end
  end
end
