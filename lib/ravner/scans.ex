defmodule Ravner.Scans do
  @moduledoc """
  The Scans context.
  """

  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Repo

  @chaos_api "https://dns.projectdiscovery.io"
  @hackertarget_api "https://api.hackertarget.com/hostsearch"

  @doc """
  Runs a subdomain discovery scan for a domain.

  Tries Chaos API first, falls back to HackerTarget if Chaos fails or no key.
  """
  def run_subdomain_scan(domain_id) do
    domain = Domains.get_domain!(domain_id)

    case run_chaos(domain.name) do
      {:ok, subdomains} ->
        save_subdomains(subdomains, domain.id)

      {:error, _} ->
        case run_hackertarget(domain.name) do
          {:ok, subdomains} ->
            save_subdomains(subdomains, domain.id)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp run_chaos(domain_name) do
    api_key = Application.get_env(:ravner, :chaos_api_key)

    if is_nil(api_key) || api_key == "" do
      {:error, "No Chaos API key"}
    else
      case Req.get("#{@chaos_api}/#{domain_name}/subdomains",
             headers: [authorization: api_key],
             retry: false,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: body}} ->
          subdomains =
            body
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          {:ok, subdomains}

        {:ok, %{status: status}} ->
          {:error, "Chaos API returned #{status}"}

        {:error, exception} ->
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

      {:ok, %{status: status}} ->
        {:error, "HackerTarget returned #{status}"}

      {:error, exception} ->
        {:error, "HackerTarget request failed: #{inspect(exception)}"}
    end
  end

  defp save_subdomains(subdomains, parent_id) do
    domain = Domains.get_domain!(parent_id)

    {new_count, results} =
      Enum.reduce(subdomains, {0, []}, fn subdomain_name, {count, acc} ->
        full_name = "#{subdomain_name}.#{domain.name}"

        case find_or_create_subdomain(full_name, parent_id) do
          {:new, sub} -> {count + 1, [sub | acc]}
          {:existing, sub} -> {count, [sub | acc]}
        end
      end)

    {:ok, %{found: length(subdomains), new: new_count, subdomains: Enum.reverse(results)}}
  end

  defp find_or_create_subdomain(name, parent_id) do
    case Repo.get_by(Domain, name: name) do
      nil ->
        {:ok, subdomain} =
          Domains.create_domain(%{
            name: name,
            type: :subdomain,
            parent_domain_id: parent_id
          })

        {:new, subdomain}

      existing ->
        {:existing, existing}
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
          scanned_at: DateTime.utc_now()
        }

        Domains.upsert_domain_metadata(domain_id, meta)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_httpx_scan(domain_name) do
    url = "https://#{domain_name}"

    case Req.get(url, max_redirects: 5, retry: false, receive_timeout: 10_000) do
      {:ok, response} ->
        server = List.first(Req.Response.get_header(response, "server"))

        security = %{
          "strict-transport-security" =>
            List.first(Req.Response.get_header(response, "strict-transport-security")),
          "content-security-policy" =>
            List.first(Req.Response.get_header(response, "content-security-policy")),
          "x-frame-options" => List.first(Req.Response.get_header(response, "x-frame-options")),
          "x-content-type-options" =>
            List.first(Req.Response.get_header(response, "x-content-type-options"))
        }

        chain =
          case response.private[:req_redirect_url] do
            nil -> []
            prev -> [%{url: to_string(prev), status: response.status}]
          end

        {:ok,
         %{
           http_status: response.status,
           final_url: to_string(response.url),
           server_header: server,
           security_headers: security,
           redirect_chain: chain
         }}

      {:error, exception} ->
        {:error, "HTTP request failed: #{inspect(exception)}"}
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
          scanned_at: DateTime.utc_now()
        }

        Domains.upsert_domain_metadata(domain_id, meta)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_dnsx_scan(domain_name) do
    task =
      Task.async(fn ->
        arg = domain_name <> "\n"
        port = Port.open({:spawn, "dnsx -a -aaaa -cname -mx -ns -txt -json -silent"}, [:binary])

        Port.command(port, arg)
        Port.command(port, :eof)

        receive do
          {^port, {:data, output}} ->
            Port.close(port)
            output
        after
          15_000 ->
            Port.close(port)
            nil
        end
      end)

    case Task.yield(task, 15_000) || Task.shutdown(task) do
      {:ok, nil} ->
        {:error, "dnsx timed out"}

      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "Failed to parse dnsx output"}
        end

      {:exit, _reason} ->
        {:error, "dnsx process crashed"}
    end
  end
end
