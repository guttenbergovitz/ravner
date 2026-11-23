defmodule Ravner.Scans.CveLookup do
  @moduledoc """
  Surface-level CVE analysis: maps detected technologies (Wappalyzer evidence
  with versions) to known vulnerabilities via the OSV.dev batch API.

  Only technologies that map to a package ecosystem (npm, PyPI, …) are
  queried — unmapped techs are skipped to avoid keyword-search noise. One
  batched request per scan keeps this cheap; no caching layer for now.
  """

  require Logger

  import Ecto.Query

  alias Ravner.Repo
  alias Ravner.Scans.HttpRetry

  @osv_batch_url "https://api.osv.dev/v1/querybatch"
  @receive_timeout 15_000
  @max_retries 2

  alias Ravner.Scans.CveCache

  # Comprehensive technology → {OSV ecosystem, package} mapping.
  # Covers modern frontend frameworks, backend runtimes, CMSs, and web servers.
  @ecosystem_map %{
    # JavaScript / TypeScript frameworks & libraries
    "next.js" => {"npm", "next"},
    "nextjs" => {"npm", "next"},
    "astro" => {"npm", "astro"},
    "payload" => {"npm", "payload"},
    "payload cms" => {"npm", "payload"},
    "vue.js" => {"npm", "vue"},
    "vue" => {"npm", "vue"},
    "nuxt.js" => {"npm", "nuxt"},
    "nuxt" => {"npm", "nuxt"},
    "svelte" => {"npm", "svelte"},
    "sveltekit" => {"npm", "@sveltejs/kit"},
    "@sveltejs/kit" => {"npm", "@sveltejs/kit"},
    "remix" => {"npm", "@remix-run/react"},
    "strapi" => {"npm", "@strapi/strapi"},
    "gatsby" => {"npm", "gatsby"},
    "react" => {"npm", "react"},
    "angular" => {"npm", "@angular/core"},
    "angularjs" => {"npm", "angular"},
    "jquery" => {"npm", "jquery"},
    "bootstrap" => {"npm", "bootstrap"},
    "lodash" => {"npm", "lodash"},
    "moment.js" => {"npm", "moment"},
    "axios" => {"npm", "axios"},
    "express" => {"npm", "express"},
    "tailwindcss" => {"npm", "tailwindcss"},

    # Python
    "django" => {"PyPI", "django"},
    "fastapi" => {"PyPI", "fastapi"},
    "flask" => {"PyPI", "flask"},

    # PHP & CMS
    "php" => {"Bitnami", "php"},
    "laravel" => {"Packagist", "laravel/framework"},
    "symfony" => {"Packagist", "symfony/symfony"},
    "drupal" => {"Packagist", "drupal/core"},
    "wordpress" => {"Bitnami", "wordpress"},

    # Web servers & infrastructure
    "apache" => {"Debian", "apache2"},
    "apache http server" => {"Debian", "apache2"},
    "nginx" => {"Debian", "nginx"},

    # Other runtimes
    "rails" => {"RubyGems", "rails"},
    "ruby on rails" => {"RubyGems", "rails"},
    "phoenix" => {"Hex", "phoenix"}
  }

  @doc """
  Returns the ecosystem mapping.
  """
  def ecosystem_map, do: @ecosystem_map

  @doc """
  Returns CVE findings for a domain based on its stored tech evidence.

  Disabled feature and no mappable evidence yield `{:ok, []}`. External source
  failures are returned so callers do not record a false clean result.
  """
  @spec lookup(integer(), String.t()) :: {:ok, [map()]}
  def lookup(domain_id, domain_name) do
    if enabled?() do
      do_lookup(domain_id, domain_name)
    else
      {:ok, []}
    end
  rescue
    e in [
      DBConnection.ConnectionError,
      Postgrex.Error,
      Req.TransportError,
      Mint.TransportError,
      RuntimeError
    ] ->
      Logger.warning("CVE lookup failed for #{domain_name}: #{inspect(e)}")
      {:ok, []}
  end

  defp do_lookup(domain_id, domain_name) do
    queries =
      Ravner.Domains.TechEvidence
      |> where([e], e.domain_id == ^domain_id)
      |> where([e], not is_nil(e.version) and e.version != "")
      |> where([e], is_nil(e.confidence) or e.confidence >= 70)
      |> where([e], is_nil(e.source) or not like(e.source, "%implied%"))
      |> select([e], {e.name, e.version})
      |> Repo.all()
      |> Enum.filter(fn {_name, version} -> valid_version?(version) end)
      |> Enum.flat_map(fn {name, version} ->
        case Map.get(@ecosystem_map, String.downcase(name)) do
          nil -> []
          {ecosystem, package} -> [{name, version, ecosystem, package}]
        end
      end)
      |> Enum.uniq()

    case queries do
      [] ->
        {:ok, []}

      _ ->
        case CveCache.fetch_batch(queries, &fetch_osv/1) do
          {:error, reason} ->
            {:error, reason}

          vulns_by_key ->
            findings =
              Enum.flat_map(queries, fn {name, version, _eco, _pkg} ->
                vulns_by_key
                |> Map.get({name, version}, [])
                |> Enum.filter(&actionable_vuln?/1)
                |> Enum.map(&finding_for(&1, name, version, domain_name))
              end)

            {:ok, findings}
        end
    end
  end

  @doc """
  Returns true if the version string is valid, non-empty, and starts with a version digit.
  """
  @spec valid_version?(term()) :: boolean()
  def valid_version?(version) when is_binary(version) do
    trimmed = String.trim(version)
    trimmed != "" and Regex.match?(~r/^\d+(\.\d+)*/, trimmed)
  end

  def valid_version?(_), do: false

  @doc false
  def actionable_vuln?(_vuln), do: true

  # ─── OSV ─────────────────────────────────────────────────────────────────

  @doc false
  def fetch_osv(queries) do
    body = %{
      queries:
        Enum.map(queries, fn {_name, version, ecosystem, package} ->
          %{"package" => %{"name" => package, "ecosystem" => ecosystem}, "version" => version}
        end)
    }

    req_opts =
      [url: @osv_batch_url, json: body, receive_timeout: @receive_timeout, retry: false]
      |> Keyword.merge(Application.get_env(:ravner, :cve_lookup_req_opts, []))

    result =
      HttpRetry.with_retry(
        fn -> Req.post(req_opts) end,
        max_retries: @max_retries
      )

    case result do
      {:ok, %Req.Response{status: 200, body: %{"results" => results}}} ->
        queries
        |> Enum.zip(results)
        |> Map.new(fn {{name, version, _, _}, result} ->
          raw_vulns = List.wrap(result["vulns"])
          hydrated_vulns = hydrate_vulns(raw_vulns)
          {{name, version}, hydrated_vulns}
        end)

      other ->
        Logger.warning("OSV querybatch failed: #{inspect(other)}")
        {:error, {:osv_unavailable, other}}
    end
  end

  defp hydrate_vulns(vulns) do
    vulns
    |> Enum.take(25)
    |> Task.async_stream(&hydrate_single_vuln/1,
      max_concurrency: 5,
      timeout: 3_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, v} -> v
      _ -> %{}
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  defp hydrate_single_vuln(%{"id" => id} = vuln) do
    if (vuln["summary"] && vuln["summary"] != "") ||
         (vuln["details"] && vuln["details"] != "") ||
         (is_list(vuln["aliases"]) and vuln["aliases"] != []) do
      vuln
    else
      url = "https://api.osv.dev/v1/vulns/#{id}"

      req_opts =
        [url: url, receive_timeout: 3_000, retry: false]
        |> Keyword.merge(Application.get_env(:ravner, :cve_lookup_req_opts, []))

      case Req.get(req_opts) do
        {:ok, %Req.Response{status: 200, body: full}} when is_map(full) ->
          Map.merge(vuln, full)

        _ ->
          vuln
      end
    end
  rescue
    _e in [Req.TransportError, Mint.TransportError, RuntimeError] -> vuln
  end

  # ─── Finding shape ───────────────────────────────────────────────────────

  defp finding_for(vuln, tech, version, domain_name) do
    id = vuln["id"] || "unknown"

    # Canonical CVE ID: prefer an explicit "CVE-..." alias, or extract from vendor ID
    cve_id =
      Enum.find(vuln["aliases"] || [], &String.starts_with?(&1, "CVE-")) ||
        case Regex.run(~r/(\d{4}-\d+)/, id) do
          [_, num] -> "CVE-#{num}"
          _ -> id
        end

    summary =
      cond do
        vuln["summary"] && vuln["summary"] != "" ->
          vuln["summary"]

        vuln["details"] && vuln["details"] != "" ->
          vuln["details"]
          |> String.split("\n")
          |> hd()
          |> String.slice(0, 140)

        true ->
          "Security vulnerability affecting #{tech}"
      end

    cvss_severity =
      get_in(vuln, ["database_specific", "severity"]) ||
        extract_cvss_severity(vuln)

    display_tech =
      if version && String.trim(version) != "" do
        "#{tech} v#{version}"
      else
        tech
      end

    raw_refs =
      vuln
      |> Map.get("references", [])
      |> Enum.map(fn
        %{"url" => url} -> url
        url when is_binary(url) -> url
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    direct_refs =
      [
        if(String.starts_with?(cve_id, "CVE-"),
          do: "https://nvd.nist.gov/vuln/detail/#{cve_id}"
        ),
        "https://osv.dev/vulnerability/#{id}"
      ]
      |> Enum.reject(&is_nil/1)

    all_refs = Enum.uniq(direct_refs ++ raw_refs) |> Enum.take(8)

    all_aliases =
      [id | vuln["aliases"] || []]
      |> Enum.reject(&(&1 == cve_id))
      |> Enum.uniq()

    %{
      severity: map_severity(cvss_severity),
      title: "#{cve_id} — #{display_tech}: #{summary}",
      target: domain_name,
      detail: %{
        "cve" => cve_id,
        "osv_id" => id,
        "tech" => tech,
        "version" => version,
        "summary" => summary,
        "description" => vuln["details"],
        "aliases" => all_aliases,
        "references" => all_refs,
        "source" => "osv.dev"
      }
    }
  end

  @doc false
  def extract_cvss_severity(vuln) do
    scores =
      for aff <- List.wrap(vuln["affected"]),
          sev <- List.wrap(aff["severity"]),
          score = sev["score"],
          is_binary(score) do
        score
      end

    case scores do
      [score | _] ->
        cond do
          String.contains?(score, "AV:N/AC:L") and String.contains?(score, "C:H/I:H/A:H") ->
            "critical"

          String.contains?(score, "C:H") or String.contains?(score, "I:H") ->
            "high"

          true ->
            "medium"
        end

      _ ->
        "medium"
    end
  end

  @doc false
  def map_severity(sev) when is_binary(sev) do
    case String.downcase(sev) do
      s when s in ["critical", "high", "medium", "low"] -> s
      _ -> "medium"
    end
  end

  @doc false
  def map_severity(_), do: "medium"

  defp enabled?, do: Application.get_env(:ravner, :cve_lookup_enabled, true)
end
