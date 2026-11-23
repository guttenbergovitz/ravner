defmodule Ravner.Scans.Http do
  @moduledoc """
  HTTP/Deep scanning using Req, Katana and native Wappalyzer fingerprinting
  (`Ravner.Scans.TechFingerprint`).
  """

  require Logger

  alias Ravner.Domains
  alias Ravner.SystemCommand

  @katana_timeout 180_000
  @tech_fingerprint_timeout 30_000
  @deep_url_limit 100
  @deep_js_limit 50
  @deep_evidence_limit 80

  defp heuristics(key, default),
    do: Application.get_env(:ravner, :heuristics, %{})[key] || default

  defp tech_stack_patterns, do: heuristics(:tech_stack_patterns, [])
  defp server_tech_map, do: heuristics(:server_tech_map, %{})
  defp hosting_platform_headers, do: heuristics(:hosting_platform_headers, [])

  @spec run_httpx_scan(integer()) ::
          {:ok, Ravner.Domains.DomainMetadata.t()} | {:error, term()}
  def run_httpx_scan(domain_id) do
    domain = Domains.get_domain!(domain_id)
    Ravner.ActivityLog.emit(:step, "Probing HTTP for #{domain.name}…")

    case do_httpx_scan(domain.name) do
      {:ok, data} ->
        if Ravner.Scans.external_redirect?(domain.name, data.final_url) do
          Ravner.ActivityLog.emit(:step, "External redirect detected → #{data.final_url}")
        end

        now = DateTime.utc_now()

        meta =
          if Ravner.Scans.external_redirect?(domain.name, data.final_url) do
            # Store only redirect-relevant data; null out target-domain fields
            redirect_status =
              data.redirect_chain
              |> List.wrap()
              |> Enum.find_value(fn
                %{status: s} when s in 300..399 -> s
                _ -> nil
              end) || data.http_status

            %{
              http_status: redirect_status,
              final_url: data.final_url,
              redirect_chain: data.redirect_chain,
              server_header: nil,
              security_headers: nil,
              tech_stack: nil,
              hosting_platform: nil,
              scanned_at: now,
              http_scanned_at: now
            }
          else
            meta = %{
              http_status: data.http_status,
              final_url: data.final_url,
              server_header: data.server_header,
              security_headers: data.security_headers,
              redirect_chain: data.redirect_chain,
              tech_stack: data.tech_stack,
              hosting_platform: data.hosting_platform,
              scanned_at: now,
              http_scanned_at: now
            }

            # Enrich with ASN if we have stored IPs from a previous DNS scan
            meta = maybe_enrich_with_asn(meta, domain_id)
            # Enrich with SSL if it is an HTTPS site
            Ravner.Scans.Ssl.enrich(meta, domain.name, data.final_url)
          end

        Domains.upsert_domain_metadata(domain_id, meta)
        Ravner.Governance.RiskScore.recalculate_for_domain(domain_id)
        maybe_update_domain_url(domain, data.final_url)
        record_technical_status_from_http(domain, data)
        Ravner.ActivityLog.emit(:done, "HTTP done — #{domain.name} → status #{data.http_status}")
        {:ok, data}

      {:error, reason} ->
        Ravner.ActivityLog.emit(
          :error,
          "HTTP probe failed for #{domain.name}: #{inspect(reason)}"
        )

        Domains.upsert_domain_metadata(domain_id, %{
          http_status: 0,
          http_scanned_at: DateTime.utc_now()
        })

        Ravner.Governance.RiskScore.recalculate_for_domain(domain_id)

        Domains.record_technical_status(domain, :error)

        if match?({:transport, _}, reason) do
          {:ok, %{error: :connection_error}}
        else
          {:error, reason}
        end
    end
  end

  @doc """
  Runs a deeper technology scan using the already stored/fresh landing URL.

  This scan is deliberately additive: the Req-based HTTP probe refreshes the
  canonical URL and lightweight fingerprints, `katana` contributes crawled
  URLs/assets, and `Ravner.Scans.TechFingerprint` contributes
  Wappalyzer-style technology evidence when available. Missing optional tools
  are recorded in metadata instead of making the whole scan fail.
  """
  @spec run_deep_tech_scan(integer()) :: {:ok, map()} | {:error, term()}
  def run_deep_tech_scan(domain_id) do
    started_at = System.monotonic_time(:millisecond)
    domain = Domains.get_domain!(domain_id)
    http_result = run_httpx_scan(domain_id)

    target_url = deep_scan_target_url(domain_id, domain)
    Ravner.ActivityLog.emit(:step, "Deep tech scan — crawling #{target_url}…")

    {crawl_data, crawl_errors, tech_evidence, fingerprint_errors} =
      if deep_http_allows_tools?(http_result) do
        Ravner.ActivityLog.emit(:step, "Running katana crawler on #{target_url}…")

        {crawl_data, crawl_errors} =
          case run_katana(target_url) do
            {:ok, data} -> {data, []}
            {:error, reason} -> {%{urls: [], js_assets: [], forms: []}, [to_string(reason)]}
          end

        Ravner.ActivityLog.emit(:step, "Fingerprinting technologies via Wappalyzer…")

        {tech_evidence, fingerprint_errors} =
          case run_tech_fingerprint(target_url) do
            {:ok, evidence} -> {evidence, []}
            {:error, reason} -> {[], [to_string(reason)]}
          end

        {crawl_data, crawl_errors, tech_evidence, fingerprint_errors}
      else
        {%{urls: [], js_assets: [], forms: []}, ["HTTP probe failed; skipped deep tools"], [], []}
      end

    previous_metadata = Domains.get_domain_metadata(domain_id)
    previous_tech_stack = if previous_metadata, do: previous_metadata.tech_stack || [], else: []
    now = DateTime.utc_now()

    tech_stack =
      previous_tech_stack
      |> Kernel.++(Enum.map(tech_evidence, & &1["name"]))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.sort()

    duration_ms = System.monotonic_time(:millisecond) - started_at
    errors = crawl_errors ++ fingerprint_errors

    metadata = %{
      tech_stack: tech_stack,
      js_assets: Enum.take(crawl_data.js_assets, @deep_js_limit),
      forms: crawl_data.forms,
      deep_scan_errors: errors,
      scanned_at: now,
      deep_tech_scanned_at: now,
      scan_duration_ms: duration_ms
    }

    with {:ok, _metadata} <- Domains.upsert_domain_metadata(domain_id, metadata),
         _ <-
           Domains.sync_tech_evidence(domain_id, Enum.take(tech_evidence, @deep_evidence_limit)),
         _ <- Domains.sync_discovered_urls(domain_id, Enum.take(crawl_data.urls, @deep_url_limit)) do
      Ravner.ActivityLog.emit(
        :done,
        "Deep tech done — #{length(tech_stack)} techs, #{length(crawl_data.urls)} URLs discovered"
      )

      {:ok,
       %{
         target_url: target_url,
         technologies: length(tech_stack),
         evidence: length(tech_evidence),
         urls: length(crawl_data.urls),
         js_assets: length(crawl_data.js_assets),
         errors: errors
       }}
    end
  end

  defp deep_http_allows_tools?({:ok, %{error: _}}), do: false
  defp deep_http_allows_tools?({:ok, _}), do: true
  defp deep_http_allows_tools?(_), do: false

  defp deep_scan_target_url(domain_id, domain) do
    metadata = Domains.get_domain_metadata(domain_id)

    [metadata && metadata.final_url, domain.url, "https://#{domain.name}"]
    |> Enum.find(&valid_url?/1)
  end

  defp valid_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] && is_binary(uri.host) && uri.host != ""
  end

  defp valid_url?(_), do: false

  defp run_katana(target_url) do
    args = ["-u", target_url, "-jsonl", "-silent", "-d", "2", "-jc", "-fx"]

    case SystemCommand.run_with_timeout("katana", args, @katana_timeout) do
      {output, 0} ->
        {:ok, parse_katana_output(output)}

      {:error, :timeout} ->
        {:error, "katana timed out after #{@katana_timeout}ms"}

      {:error, reason} ->
        {:error, reason}

      {output, code} ->
        {:error, "katana failed (exit #{code}): #{String.slice(output, 0, 200)}"}
    end
  end

  # The target URL is already the canonical landing URL, so no redirect
  # following is needed here — katana handles crawling separately.
  defp run_tech_fingerprint(target_url) do
    case Req.get(target_url,
           redirect: false,
           retry: false,
           decode_body: false,
           receive_timeout: @tech_fingerprint_timeout
         ) do
      {:ok, response} ->
        case Ravner.Scans.TechFingerprint.analyze(target_url, response) do
          {:ok, evidence} -> {:ok, evidence}
          {:error, :fingerprints_not_found} -> {:error, "technologies database not found"}
          {:error, reason} -> {:error, reason}
        end

      {:error, exception} ->
        {:error, "tech fingerprint fetch failed: #{inspect(exception)}"}
    end
  end

  @doc false
  @spec parse_katana_output(String.t()) :: %{
          urls: [map()],
          js_assets: [String.t()],
          forms: [map()]
        }
  def parse_katana_output(output) when is_binary(output) do
    {entries, plain_urls} =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce({[], []}, fn line, {entries, plain_urls} ->
        case Jason.decode(line) do
          {:ok, data} when is_map(data) ->
            {[data | entries], plain_urls}

          _ ->
            if valid_url?(line), do: {entries, [line | plain_urls]}, else: {entries, plain_urls}
        end
      end)

    urls =
      Enum.reverse(entries)
      |> Enum.flat_map(&katana_url_entries/1)
      |> Kernel.++(Enum.reverse(plain_urls) |> Enum.map(&%{"url" => &1, "source" => "katana"}))
      |> dedupe_maps_by("url")
      |> Enum.take(@deep_url_limit)

    js_assets =
      urls
      |> Enum.map(& &1["url"])
      |> Enum.filter(&js_asset_url?/1)
      |> Enum.uniq()
      |> Enum.take(@deep_js_limit)

    forms =
      entries
      |> Enum.reverse()
      |> Enum.flat_map(&katana_form_entries/1)
      |> dedupe_maps_by("url")

    %{urls: urls, js_assets: js_assets, forms: forms}
  end

  defp katana_url_entries(data) do
    data
    |> extract_urls()
    |> Enum.map(fn url ->
      %{
        "url" => url,
        "source" => to_string(data["source"] || data["tag"] || "katana")
      }
    end)
  end

  defp extract_urls(value) when is_binary(value) do
    if valid_url?(value), do: [value], else: []
  end

  defp extract_urls(value) when is_list(value), do: Enum.flat_map(value, &extract_urls/1)

  defp extract_urls(value) when is_map(value) do
    value
    |> Enum.flat_map(fn {key, nested} ->
      key = to_string(key)

      cond do
        key in ["url", "endpoint", "href", "src", "action"] -> extract_urls(nested)
        is_map(nested) or is_list(nested) -> extract_urls(nested)
        true -> []
      end
    end)
  end

  defp extract_urls(_), do: []

  defp katana_form_entries(data) do
    for action <- extract_form_actions(data) do
      %{
        "url" => action,
        "method" => to_string(data["method"] || "GET"),
        "source" => "katana"
      }
    end
  end

  defp extract_form_actions(%{"tag" => "form"} = data),
    do: extract_urls(data["attribute"] || data)

  defp extract_form_actions(_), do: []

  defp js_asset_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    path = uri.path || ""
    String.ends_with?(String.downcase(path), ".js")
  end

  defp js_asset_url?(_), do: false

  defp dedupe_maps_by(maps, key) do
    maps
    |> Enum.reject(&(Map.get(&1, key) in [nil, ""]))
    |> Enum.uniq_by(&Map.get(&1, key))
  end

  defp maybe_enrich_with_asn(meta, domain_id) do
    case get_stored_ipv4(domain_id) do
      [ip | _] ->
        case lookup_asn(ip) do
          {:ok, asn_data} -> Map.merge(meta, asn_data)
          _ -> meta
        end

      _ ->
        meta
    end
  end

  defp record_technical_status_from_http(domain, data) do
    is_redirect = external_redirect?(domain.name, data.final_url)

    status =
      cond do
        is_redirect -> :redirect
        data.http_status >= 400 -> :error
        String.starts_with?(data.final_url, "http://") -> :insecure
        data.http_status == 200 -> :reachable
        true -> :unknown
      end

    if status != :unknown do
      Domains.record_technical_status(domain, status)
    end

    # Auto-detect redirect lifecycle state
    if is_redirect do
      Domains.record_redirect_lifecycle(domain, data.final_url)
    end
  end

  defp maybe_update_domain_url(domain, final_url) when is_binary(final_url) and final_url != "" do
    if domain.url != final_url do
      Domains.record_scanner_domain_update(domain, %{url: final_url})
    end
  end

  defp maybe_update_domain_url(_domain, _final_url), do: :ok

  defp external_redirect?(domain_name, final_url),
    do: Ravner.Scans.external_redirect?(domain_name, final_url)

  defp do_httpx_scan(domain_name) do
    https_url = "https://#{domain_name}"
    http_url = "http://#{domain_name}"

    result =
      case follow_redirects(https_url) do
        {:ok, _} = ok ->
          ok

        {:error, {:transport, :tls_error}} ->
          Logger.info("TLS failed for #{domain_name}, retrying over HTTP")
          follow_redirects(http_url)

        {:error, {:transport, :nxdomain}} = err ->
          err

        {:error, _} ->
          # Any other HTTPS error: also try plain HTTP as fallback
          follow_redirects(http_url)
      end

    case result do
      {:ok, {chain, final_response, final_url}} ->
        server = List.first(Req.Response.get_header(final_response, "server"))

        security = %{
          "strict-transport-security" =>
            List.first(Req.Response.get_header(final_response, "strict-transport-security")),
          "content-security-policy" =>
            List.first(Req.Response.get_header(final_response, "content-security-policy")),
          "x-frame-options" =>
            List.first(Req.Response.get_header(final_response, "x-frame-options")),
          "x-content-type-options" =>
            List.first(Req.Response.get_header(final_response, "x-content-type-options"))
        }

        body_str = if is_binary(final_response.body), do: final_response.body, else: ""
        tech_stack = detect_tech_stack(final_response, body_str)
        hosting_platform = detect_hosting_platform(final_response)

        {:ok,
         %{
           http_status: final_response.status,
           final_url: final_url,
           server_header: server,
           security_headers: security,
           redirect_chain: chain,
           tech_stack: tech_stack,
           hosting_platform: hosting_platform
         }}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # Follow redirects manually to capture the full hop-by-hop chain
  defp follow_redirects(url, chain \\ [], hops_left \\ 10)

  defp follow_redirects(_url, chain, 0) do
    {:error, "Too many redirects after #{length(chain)} hops"}
  end

  defp follow_redirects(url, chain, hops_left) do
    case Req.get(url,
           redirect: false,
           retry: false,
           receive_timeout: 8_000,
           raw: false
         ) do
      {:ok, response} ->
        hop = %{url: url, status: response.status}

        if response.status in 300..399 do
          case List.first(Req.Response.get_header(response, "location")) do
            nil ->
              {:ok, {Enum.reverse([hop | chain]), response, url}}

            location ->
              next_url = resolve_redirect_url(url, location)
              follow_redirects(next_url, [hop | chain], hops_left - 1)
          end
        else
          # Check for client-side redirects (meta refresh or immediate JS redirects)
          # in lightweight stub pages (e.g. <= 5_000 bytes)
          case maybe_extract_client_redirect(response, url, chain) do
            {:ok, next_url} ->
              follow_redirects(next_url, [hop | chain], hops_left - 1)

            :none ->
              {:ok, {Enum.reverse([hop | chain]), response, url}}
          end
        end

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport, classify_transport_error(reason)}}

      {:error, e} ->
        {:error, "HTTP request failed: #{inspect(e)}"}
    end
  end

  @max_redirect_stub_bytes 5_000

  defp maybe_extract_client_redirect(response, current_url, chain) do
    if response.status in 200..299 and is_binary(response.body) and
         byte_size(response.body) <= @max_redirect_stub_bytes do
      case extract_client_redirect_target(response.body) do
        nil ->
          :none

        target ->
          next_url = resolve_redirect_url(current_url, target)
          already_visited? = Enum.any?(chain, fn hop -> hop.url == next_url end)

          if next_url != current_url and not already_visited? do
            {:ok, next_url}
          else
            :none
          end
      end
    else
      :none
    end
  end

  defp extract_client_redirect_target(body) do
    # 1. Meta refresh: <meta http-equiv="refresh" content="0; url=...">
    meta_target =
      case Regex.run(
             ~r/<meta[^>]+http-equiv=["']?refresh["']?[^>]+content=["']?[^"'>]*url=([^"'>\s]+)/i,
             body
           ) do
        [_, url] -> String.trim(url, "\"'")
        _ -> nil
      end

    # 2. Immediate JS redirect or window.onload redirect
    js_target =
      if is_nil(meta_target) do
        patterns = [
          ~r/window\.onload\s*=\s*(?:function\s*\([^)]*\)\s*\{|\([^)]*\)\s*=>\s*\{)?\s*(?:window\.|document\.)?location(?:\.href|\.replace)?\s*=\s*['"]([^'"]+)['"]/i,
          ~r/window\.onload\s*=\s*(?:function\s*\([^)]*\)\s*\{|\([^)]*\)\s*=>\s*\{)?\s*(?:window\.|document\.)?location\.replace\(['"]([^'"]+)['"]\)/i,
          ~r/<script[^>]*>\s*(?:window\.|document\.)?location(?:\.href|\.replace)?\s*=\s*['"]([^'"]+)['"]/i,
          ~r/<script[^>]*>\s*(?:window\.|document\.)?location\.replace\(['"]([^'"]+)['"]\)/i
        ]

        Enum.find_value(patterns, fn regex ->
          case Regex.run(regex, body) do
            [_, url] -> String.trim(url)
            _ -> nil
          end
        end)
      else
        nil
      end

    meta_target || js_target
  end

  defp classify_transport_error(:nxdomain), do: :nxdomain
  defp classify_transport_error(:timeout), do: :timeout
  defp classify_transport_error(:econnrefused), do: :connection_refused
  defp classify_transport_error({:tls_alert, _}), do: :tls_error
  defp classify_transport_error(:closed), do: :connection_closed
  defp classify_transport_error(_), do: :connection_error

  defp resolve_redirect_url(base_url, location) do
    location = String.trim(location)

    cond do
      String.starts_with?(location, "http://") or String.starts_with?(location, "https://") ->
        location

      String.starts_with?(location, "//") ->
        uri = URI.parse(base_url)
        "#{uri.scheme || "https"}:#{location}"

      String.starts_with?(location, "/") ->
        uri = URI.parse(base_url)
        port_suffix = if uri.port && uri.port not in [80, 443], do: ":#{uri.port}", else: ""
        "#{uri.scheme || "https"}://#{uri.host}#{port_suffix}#{location}"

      true ->
        uri = URI.parse(base_url)
        port_suffix = if uri.port && uri.port not in [80, 443], do: ":#{uri.port}", else: ""
        base_path = uri.path || "/"
        dir = Path.dirname(base_path)
        new_path = if dir in ["/", "."], do: "/#{location}", else: "#{dir}/#{location}"
        "#{uri.scheme || "https"}://#{uri.host}#{port_suffix}#{new_path}"
    end
  end

  defp detect_tech_stack(response, body_str) do
    from_powered_by =
      case List.first(Req.Response.get_header(response, "x-powered-by")) do
        nil -> []
        val -> [val]
      end

    from_generator =
      case List.first(Req.Response.get_header(response, "x-generator")) do
        nil -> []
        val -> [val]
      end

    from_server =
      case List.first(Req.Response.get_header(response, "server")) do
        nil ->
          []

        val ->
          Enum.reduce(server_tech_map(), [], fn {pattern, name}, acc ->
            if String.contains?(val, pattern), do: [name | acc], else: acc
          end)
      end

    from_body = detect_tech_from_body(body_str)

    (from_powered_by ++ from_generator ++ from_server ++ from_body)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp detect_tech_from_body(""), do: []

  defp detect_tech_from_body(body) when is_binary(body) do
    Enum.flat_map(tech_stack_patterns(), fn
      {regex, :capture} ->
        case Regex.run(regex, body, capture: :all_but_first) do
          [match | _] -> [match]
          _ -> []
        end

      {regex, name} ->
        if Regex.match?(regex, body), do: [name], else: []
    end)
    |> Enum.uniq()
  end

  defp detect_tech_from_body(_), do: []

  defp detect_hosting_platform(response) do
    Enum.find_value(hosting_platform_headers(), fn {header, platform} ->
      if List.first(Req.Response.get_header(response, header)) != nil, do: platform
    end)
  end

  defp lookup_asn(ip) do
    case Req.get("https://ipinfo.io/#{ip}/json",
           retry: false,
           receive_timeout: 5_000,
           headers: [{"accept", "application/json"}]
         ) do
      {:ok, %{status: 200, body: %{"org" => org}}} when is_binary(org) ->
        case Regex.run(~r/^(AS\d+)\s+(.+)$/, org) do
          [_, asn_num, asn_name] -> {:ok, %{asn_number: asn_num, asn_org: asn_name}}
          _ -> {:ok, %{asn_org: org}}
        end

      _ ->
        {:error, "ASN lookup failed"}
    end
  end

  defp get_stored_ipv4(domain_id) do
    case Domains.get_domain_metadata(domain_id) do
      nil -> []
      meta -> meta.ip_v4 || []
    end
  end
end
