defmodule Ravner.Scans do
  @moduledoc """
  The Scans context.
  """

  require Logger

  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Repo

  @chaos_api "https://dns.projectdiscovery.io"
  @hackertarget_api "https://api.hackertarget.com/hostsearch"
  @crtsh_api "https://crt.sh"
  @rdap_api "https://rdap.org/domain"
  @iana_bootstrap "https://data.iana.org/rdap/dns.json"

  # Nameserver suffix → registrar name heuristics
  @ns_registrar_patterns [
    {"domaincontrol.com", "GoDaddy"},
    {"godaddy.com", "GoDaddy"},
    {"namecheaphosting.com", "Namecheap"},
    {"namecheap.com", "Namecheap"},
    {"cloudflare.com", "Cloudflare"},
    {"name-services.com", "Enom"},
    {"enom.com", "Enom"},
    {"registrar-servers.com", "Namecheap"},
    {"ovh.net", "OVH"},
    {"ovh.com", "OVH"},
    {"hichina.com", "Alibaba Cloud"},
    {"aliyun.com", "Alibaba Cloud"},
    {"awsdns", "Amazon Route 53"},
    {"azure-dns.com", "Azure DNS"},
    {"azure-dns.net", "Azure DNS"},
    {"azure-dns.org", "Azure DNS"},
    {"azure-dns.info", "Azure DNS"},
    {"googledomains.com", "Google Domains"},
    {"dns.google.com", "Google"},
    {"1and1.com", "IONOS"},
    {"ionos.com", "IONOS"},
    {"wpengine.com", "WP Engine"},
    {"netlify.com", "Netlify"},
    {"nsone.net", "NS1"},
    {"dnsimple.com", "DNSimple"},
    {"hover.com", "Hover"},
    {"gandi.net", "Gandi"},
    {"sav.com", "SAV"},
    {"dynadot.com", "Dynadot"},
    {"porkbun.com", "Porkbun"},
    {"name.com", "Name.com"},
    {"register.com", "Register.com"},
    {"networksolutions.com", "Network Solutions"},
    {"uniregistry.net", "Uniregistry"},
    {"fastly.net", "Fastly"},
    {"dns.com", "DNS.com"},
    {"rcode0.net", "RcodeZero"},
    {"dnsnode.net", "Netnod"},
    {"home.pl", "home.pl"},
    {"aftermarket.pl", "AfterMarket.pl"},
    {"kei.pl", "KEI"},
    {"nazwa.pl", "nazwa.pl"}
  ]

  @doc """
  Runs a subdomain discovery scan for a domain.

  Tries Chaos API first, falls back to HackerTarget if Chaos fails or no key.
  """
  def run_subdomain_scan(domain_id) do
    domain = Domains.get_domain!(domain_id)

    # Subdomain discovery only makes sense for apex domains
    if domain.parent_domain_id != nil do
      Logger.info("Skipping subdomain scan for non-apex domain #{domain.name}")
      {:error, "Subdomain scan only supported for apex domains"}
    else
      result = run_subdomain_sources(domain.name, domain.id)

      case result do
        {:ok, _} = ok ->
          Domains.upsert_domain_metadata(domain_id, %{subdomains_scanned_at: DateTime.utc_now()})
          ok

        error ->
          error
      end
    end
  end

  # Tries each source in order, returning on first success.
  # Chain: Chaos → HackerTarget → crt.sh
  defp run_subdomain_sources(domain_name, domain_id) do
    sources = [
      fn -> run_chaos(domain_name) end,
      fn -> run_hackertarget(domain_name) end,
      fn -> run_crtsh(domain_name) end
    ]

    Enum.reduce_while(sources, {:error, "All subdomain sources exhausted"}, fn source, _acc ->
      case source.() do
        {:ok, subdomains} ->
          {:halt, save_subdomains(subdomains, domain_id)}

        {:error, reason} ->
          Logger.info("Subdomain source failed for #{domain_name}: #{reason}, trying next")
          {:cont, {:error, reason}}
      end
    end)
  end

  defp run_chaos(domain_name) do
    api_key = Application.get_env(:ravner, :chaos_api_key)

    if is_nil(api_key) || api_key == "" do
      {:error, "No Chaos API key"}
    else
      case Req.get("#{@chaos_api}/dns/#{domain_name}/subdomains",
             headers: %{"authorization" => api_key},
             retry: false,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: %{"subdomains" => subdomains}}} when is_list(subdomains) ->
          {:ok, subdomains}

        {:ok, %{status: 200, body: body}} ->
          Logger.warning("Chaos API unexpected body for #{domain_name}: #{inspect(body)}")
          {:error, "Chaos API returned unexpected response format"}

        {:ok, %{status: 404}} ->
          {:error, "Chaos has no data for #{domain_name}"}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("Chaos API error #{status} for #{domain_name}: #{inspect(body)}")
          {:error, "Chaos API returned #{status}"}

        {:error, exception} ->
          Logger.warning("Chaos request failed for #{domain_name}: #{inspect(exception)}")
          {:error, "Chaos request failed: #{inspect(exception)}"}
      end
    end
  end

  defp run_hackertarget(domain_name) do
    case Req.get("#{@hackertarget_api}/?q=#{domain_name}",
           retry: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        if is_binary(body) and
             (body =~ "API count exceeded" or body =~ "error check your" or
                body =~ "invalid host") do
          Logger.warning(
            "HackerTarget quota/error for #{domain_name}: #{String.slice(body, 0, 100)}"
          )

          {:error, "HackerTarget: #{String.trim(body)}"}
        else
          lines =
            body
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          subdomains =
            lines
            |> Enum.map(fn line ->
              case String.split(line, ",") do
                [subdomain, _ip] -> subdomain
                _ -> line
              end
            end)
            |> Enum.map(fn full ->
              if String.ends_with?(full, ".#{domain_name}") do
                String.replace_suffix(full, ".#{domain_name}", "")
              else
                full
              end
            end)
            |> Enum.reject(&(&1 == ""))
            |> Enum.uniq()

          {:ok, subdomains}
        end

      {:ok, %{status: status}} ->
        {:error, "HackerTarget returned #{status}"}

      {:error, exception} ->
        {:error, "HackerTarget request failed: #{inspect(exception)}"}
    end
  end

  defp run_crtsh(domain_name) do
    case Req.get("#{@crtsh_api}/?q=%25.#{domain_name}&output=json",
           retry: false,
           receive_timeout: 20_000
         ) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        subdomains =
          body
          |> Enum.flat_map(fn entry ->
            entry
            |> Map.get("name_value", "")
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.map(&String.trim_leading(&1, "*."))
          end)
          |> Enum.filter(&String.ends_with?(&1, ".#{domain_name}"))
          |> Enum.map(&String.replace_suffix(&1, ".#{domain_name}", ""))
          |> Enum.reject(&(&1 == "" or &1 == domain_name))
          |> Enum.uniq()

        if subdomains == [] do
          {:error, "crt.sh returned no subdomains for #{domain_name}"}
        else
          {:ok, subdomains}
        end

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Logger.warning(
          "crt.sh unexpected text body for #{domain_name}: #{String.slice(body, 0, 100)}"
        )

        {:error, "crt.sh returned unexpected response"}

      {:ok, %{status: status}} ->
        {:error, "crt.sh returned #{status}"}

      {:error, exception} ->
        Logger.warning("crt.sh request failed for #{domain_name}: #{inspect(exception)}")
        {:error, "crt.sh request failed: #{inspect(exception)}"}
    end
  end

  defp save_subdomains(subdomains, parent_id) do
    domain = Domains.get_domain!(parent_id)

    {new_count, results} =
      Enum.reduce(subdomains, {0, []}, fn subdomain_name, {count, acc} ->
        # Normalize: some sources return full FQDNs, others return just the prefix
        full_name =
          if String.ends_with?(subdomain_name, ".#{domain.name}") || subdomain_name == domain.name do
            subdomain_name
          else
            "#{subdomain_name}.#{domain.name}"
          end

        case find_or_create_subdomain(full_name, parent_id) do
          {:new, sub} -> {count + 1, [sub | acc]}
          {:existing, sub} -> {count, [sub | acc]}
          {:skip, _} -> {count, acc}
        end
      end)

    {:ok, %{found: length(subdomains), new: new_count, subdomains: Enum.reverse(results)}}
  end

  defp find_or_create_subdomain(name, parent_id) do
    case Repo.get_by(Domain, name: name) do
      nil ->
        case Domains.create_domain(%{
               name: name,
               type: :subdomain,
               parent_domain_id: parent_id
             }) do
          {:ok, subdomain} ->
            {:new, subdomain}

          {:error, changeset} ->
            errors =
              Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
                Enum.reduce(opts, msg, fn {key, value}, acc ->
                  String.replace(acc, "%{#{key}}", to_string(value))
                end)
              end)

            Logger.warning("Skipping invalid subdomain #{inspect(name)}: #{inspect(errors)}")
            {:skip, nil}
        end

      existing ->
        # Re-link to parent if orphaned (parent was deleted) or pointing to wrong parent
        subdomain =
          if existing.parent_domain_id != parent_id do
            {:ok, updated} =
              Domains.update_domain(existing, %{parent_domain_id: parent_id})

            updated
          else
            existing
          end

        {:existing, subdomain}
    end
  end

  # HTTPX scan via Req (fast, non-blocking)

  def run_httpx_scan(domain_id) do
    domain = Domains.get_domain!(domain_id)

    case do_httpx_scan(domain.name) do
      {:ok, data} ->
        meta = %{
          http_status: data.http_status,
          final_url: data.final_url,
          server_header: data.server_header,
          security_headers: data.security_headers,
          redirect_chain: data.redirect_chain,
          tech_stack: data.tech_stack,
          hosting_platform: data.hosting_platform,
          scanned_at: DateTime.utc_now(),
          http_scanned_at: DateTime.utc_now()
        }

        # Enrich with ASN if we have stored IPs from a previous DNS scan
        meta =
          case get_stored_ipv4(domain_id) do
            [ip | _] ->
              case lookup_asn(ip) do
                {:ok, asn_data} -> Map.merge(meta, asn_data)
                _ -> meta
              end

            _ ->
              meta
          end

        Domains.upsert_domain_metadata(domain_id, meta)

      {:error, {:transport, kind}} ->
        Domains.upsert_domain_metadata(domain_id, %{
          http_status: 0,
          http_scanned_at: DateTime.utc_now()
        })

        {:ok, %{error: kind}}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
          {:ok, {Enum.reverse([hop | chain]), response, url}}
        end

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport, classify_transport_error(reason)}}

      {:error, e} ->
        {:error, "HTTP request failed: #{inspect(e)}"}
    end
  end

  defp classify_transport_error(:nxdomain), do: :nxdomain
  defp classify_transport_error(:timeout), do: :timeout
  defp classify_transport_error(:econnrefused), do: :connection_refused
  defp classify_transport_error({:tls_alert, _}), do: :tls_error
  defp classify_transport_error(:closed), do: :connection_closed
  defp classify_transport_error(_), do: :connection_error

  defp resolve_redirect_url(base_url, location) do
    if String.starts_with?(location, "http://") || String.starts_with?(location, "https://") do
      location
    else
      uri = URI.parse(base_url)
      "#{uri.scheme}://#{uri.host}#{location}"
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
          cond do
            String.contains?(val, "nginx") -> ["nginx"]
            String.contains?(val, "Apache") -> ["Apache"]
            String.contains?(val, "IIS") -> ["IIS"]
            String.contains?(val, "Caddy") -> ["Caddy"]
            String.contains?(val, "LiteSpeed") -> ["LiteSpeed"]
            true -> []
          end
      end

    from_body = detect_tech_from_body(body_str)

    (from_powered_by ++ from_generator ++ from_server ++ from_body)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp detect_tech_from_body(""), do: []

  defp detect_tech_from_body(body) when is_binary(body) do
    patterns = [
      {~r/<meta[^>]+name="generator"[^>]+content="([^"]+)"/i, :capture},
      {~r/wp-content\//i, "WordPress"},
      {~r/wp-includes\//i, "WordPress"},
      {~r/cdn\.shopify\.com/i, "Shopify"},
      {~r/Shopify\.theme/i, "Shopify"},
      {~r/__nuxt/i, "Nuxt.js"},
      {~r/__NEXT_DATA__/i, "Next.js"},
      {~r/ng-version=/i, "Angular"},
      {~r/data-reactroot/i, "React"},
      {~r/window\.Squarespace/i, "Squarespace"},
      {~r/static\.wixstatic\.com/i, "Wix"},
      {~r/drupal\.js|drupalSettings/i, "Drupal"},
      {~r/Joomla!/i, "Joomla"},
      {~r/ghost\.org|ghost-theme/i, "Ghost"},
      {~r/webflow\.com/i, "Webflow"}
    ]

    Enum.flat_map(patterns, fn
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
    cond do
      has_header?(response, "cf-ray") -> "Cloudflare"
      has_header?(response, "cf-cache-status") -> "Cloudflare"
      has_header?(response, "x-amz-cf-id") -> "AWS CloudFront"
      has_header?(response, "x-amz-request-id") -> "AWS"
      has_header?(response, "x-vercel-id") -> "Vercel"
      has_header?(response, "x-nf-request-id") -> "Netlify"
      has_header?(response, "x-github-request-id") -> "GitHub Pages"
      has_header?(response, "x-fastly-request-id") -> "Fastly"
      has_header?(response, "x-azure-ref") -> "Azure"
      has_header?(response, "x-wix-request-id") -> "Wix"
      true -> nil
    end
  end

  defp has_header?(response, name) do
    List.first(Req.Response.get_header(response, name)) != nil
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

  # DNSX scan via Port + dnsx CLI

  def run_dnsx_scan(domain_id) do
    domain = Domains.get_domain!(domain_id)

    case do_dnsx_scan(domain.name) do
      {:ok, data} ->
        ip_v4 = data["a"] || []
        ip_v6 = data["aaaa"] || []

        records =
          Enum.flat_map(~w(a aaaa mx ns txt cname), fn type ->
            case data[type] do
              vals when is_list(vals) ->
                Enum.map(vals, fn val ->
                  %{type: String.upcase(type), value: to_string(val), ttl: data["ttl"]}
                end)

              nil ->
                []

              val ->
                [%{type: String.upcase(type), value: to_string(val), ttl: data["ttl"]}]
            end
          end)

        meta = %{
          ip_v4: ip_v4,
          ip_v6: ip_v6,
          dns_records: records,
          scanned_at: DateTime.utc_now(),
          dns_scanned_at: DateTime.utc_now()
        }

        Domains.upsert_domain_metadata(domain_id, meta)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_dnsx_scan(domain_name) do
    case System.cmd("/bin/sh", [
           "-c",
           "echo #{domain_name} | dnsx -a -aaaa -cname -mx -ns -txt -json -silent 2>/dev/null"
         ]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "Failed to parse dnsx output"}
        end

      {output, code} ->
        {:error, "dnsx failed (exit #{code}): #{String.slice(output, 0, 200)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # RDAP / WHOIS / NS-heuristics scan
  # Fallback chain: RDAP HTTP → WHOIS CLI → NS heuristics (from stored DNS data)
  # ---------------------------------------------------------------------------

  @doc """
  Runs registration scan for a domain.
  Falls back through: RDAP → WHOIS → NS heuristics.
  Saves whatever it finds and records the source.
  """
  def run_rdap_scan(domain_id) do
    domain = Domains.get_domain!(domain_id)
    ns_records = get_stored_ns_records(domain_id)

    {data, source} =
      case do_rdap_scan(domain.name) do
        {:ok, result} ->
          {result, "rdap"}

        {:error, _} ->
          case do_whois_scan(domain.name) do
            {:ok, result} ->
              {result, "whois"}

            {:error, _} ->
              case do_ns_heuristics(ns_records) do
                {:ok, result} -> {result, "ns_heuristics"}
                {:error, _} -> {%{}, "none"}
              end
          end
      end

    meta =
      Map.merge(data, %{
        rdap_scanned_at: DateTime.utc_now(),
        scanned_at: DateTime.utc_now()
      })

    case Domains.upsert_domain_metadata(domain_id, meta) do
      {:ok, _} -> {:ok, %{source: source, data: data}}
      error -> error
    end
  end

  # Step 1: RDAP via HTTP (rdap.org proxy → correct registry RDAP server)
  defp do_rdap_scan(domain_name) do
    case Req.get("#{@rdap_api}/#{domain_name}",
           retry: false,
           receive_timeout: 15_000,
           redirect: true
         ) do
      {:ok, %{status: 200, body: body}} ->
        parse_rdap_response(body)

      {:ok, %{status: 404}} ->
        # rdap.org doesn't know this TLD — try IANA bootstrap
        do_rdap_via_bootstrap(domain_name)

      {:ok, %{status: status}} ->
        {:error, "RDAP returned #{status}"}

      {:error, reason} ->
        {:error, "RDAP request failed: #{inspect(reason)}"}
    end
  end

  defp do_rdap_via_bootstrap(domain_name) do
    tld = domain_name |> String.split(".") |> List.last()

    with {:ok, %{status: 200, body: bootstrap}} <-
           Req.get(@iana_bootstrap, retry: false, receive_timeout: 10_000),
         services when is_list(services) <- get_in(bootstrap, ["services"]),
         rdap_url when not is_nil(rdap_url) <- find_rdap_url_for_tld(services, tld) do
      case Req.get("#{rdap_url}domain/#{domain_name}",
             retry: false,
             receive_timeout: 15_000
           ) do
        {:ok, %{status: 200, body: body}} -> parse_rdap_response(body)
        _ -> {:error, "Bootstrap RDAP failed"}
      end
    else
      _ -> {:error, "No RDAP server found via IANA bootstrap for .#{tld}"}
    end
  end

  defp find_rdap_url_for_tld(services, tld) do
    Enum.find_value(services, fn [tlds, urls] ->
      if tld in tlds, do: List.first(urls)
    end)
  end

  defp parse_rdap_response(body) when is_map(body) do
    registrar =
      body
      |> Map.get("entities", [])
      |> Enum.find_value(fn entity ->
        roles = Map.get(entity, "roles", [])

        if "registrar" in roles do
          get_in(entity, ["vcardArray", Access.at(1)])
          |> List.wrap()
          |> Enum.find_value(fn
            ["fn", _, _, name] -> name
            _ -> nil
          end)
        end
      end)

    registration_date =
      parse_rdap_date(
        Map.get(body, "registrationDate") ||
          Map.get(body, "events") |> find_event_date("registration")
      )

    expiration_date =
      parse_rdap_date(
        Map.get(body, "expirationDate") ||
          Map.get(body, "events") |> find_event_date("expiration")
      )

    if is_nil(registrar) && is_nil(registration_date) && is_nil(expiration_date) do
      {:error, "RDAP response had no useful data"}
    else
      {:ok,
       %{
         registrar: registrar,
         registration_date: registration_date,
         expiration_date: expiration_date
       }}
    end
  end

  defp parse_rdap_response(_), do: {:error, "Invalid RDAP response"}

  defp find_event_date(nil, _), do: nil

  defp find_event_date(events, action) when is_list(events) do
    Enum.find_value(events, fn event ->
      if Map.get(event, "eventAction") == action, do: Map.get(event, "eventDate")
    end)
  end

  defp parse_rdap_date(nil), do: nil

  defp parse_rdap_date(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  # Step 2: WHOIS via CLI
  defp do_whois_scan(domain_name) do
    case System.cmd("whois", [domain_name], stderr_to_stdout: true) do
      {output, 0} ->
        result = parse_whois_output(output)

        if map_size(result) == 0 do
          {:error, "WHOIS returned no parseable data"}
        else
          {:ok, Map.put(result, :whois_raw, String.slice(output, 0, 4000))}
        end

      {_output, _code} ->
        {:error, "whois command failed"}
    end
  end

  defp parse_whois_output(output) do
    lines = String.split(output, "\n")

    Enum.reduce(lines, %{}, fn line, acc ->
      line = String.trim(line)

      cond do
        match_whois_field(line, ["Registrar:", "registrar:"]) ->
          Map.put_new(acc, :registrar, extract_whois_value(line))

        match_whois_field(line, ["Registrant Organization:", "org:", "Organisation:"]) ->
          Map.put_new(acc, :registrant_org, extract_whois_value(line))

        match_whois_field(line, ["Creation Date:", "created:", "Registered on:"]) ->
          case parse_whois_date(extract_whois_value(line)) do
            nil -> acc
            dt -> Map.put_new(acc, :registration_date, dt)
          end

        match_whois_field(line, ["Registry Expiry Date:", "Expiry date:", "expire:", "paid-till:"]) ->
          case parse_whois_date(extract_whois_value(line)) do
            nil -> acc
            dt -> Map.put_new(acc, :expiration_date, dt)
          end

        true ->
          acc
      end
    end)
  end

  defp match_whois_field(line, prefixes) do
    Enum.any?(prefixes, &String.starts_with?(line, &1))
  end

  defp extract_whois_value(line) do
    line
    |> String.split(":", parts: 2)
    |> List.last()
    |> String.trim()
  end

  defp parse_whois_date(str) do
    formats = [
      &DateTime.from_iso8601/1,
      fn s ->
        case NaiveDateTime.from_iso8601(s) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC"), 0}
          err -> err
        end
      end
    ]

    Enum.find_value(formats, fn parser ->
      case parser.(str) do
        {:ok, dt, _} -> DateTime.truncate(dt, :second)
        _ -> nil
      end
    end)
  end

  # Step 3: NS heuristics — match nameservers against known registrar patterns
  defp do_ns_heuristics([]), do: {:error, "No NS records available"}

  defp do_ns_heuristics(ns_records) do
    registrar =
      Enum.find_value(ns_records, fn ns ->
        ns_lower = String.downcase(ns)

        Enum.find_value(@ns_registrar_patterns, fn {pattern, name} ->
          if String.contains?(ns_lower, pattern), do: name
        end)
      end)

    if registrar do
      {:ok, %{registrar: registrar}}
    else
      {:error, "No NS pattern matched"}
    end
  end

  defp get_stored_ns_records(domain_id) do
    case Domains.get_domain_metadata(domain_id) do
      nil ->
        []

      meta ->
        (meta.dns_records || [])
        |> Enum.filter(fn r -> r["type"] == "NS" end)
        |> Enum.map(fn r -> r["value"] end)
        |> Enum.reject(&is_nil/1)
    end
  end
end
