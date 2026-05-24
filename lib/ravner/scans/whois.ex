defmodule Ravner.Scans.Whois do
  @moduledoc """
  RDAP and WHOIS scanning with NS heuristics fallback.
  """

  import Ecto.Query

  alias Ravner.Domains
  alias Ravner.Repo
  alias Ravner.SystemCommand

  @rdap_api "https://rdap.org/domain"
  @iana_bootstrap "https://data.iana.org/rdap/dns.json"
  @whois_timeout 30_000

  defp heuristics(key, default),
    do: Application.get_env(:ravner, :heuristics, %{})[key] || default

  defp ns_registrar_patterns, do: heuristics(:ns_registrar_patterns, [])

  @doc """
  Runs registration scan for a domain.
  Falls back through: RDAP → WHOIS → NS heuristics.
  Saves whatever it finds and records the source.
  """
  @spec run_rdap_scan(integer()) :: {:ok, map()} | {:error, term()}
  def run_rdap_scan(domain_id) do
    domain = Domains.get_domain!(domain_id)
    ns_records = get_stored_ns_records(domain_id)

    {data, source} = fetch_registration_data(domain.name, ns_records)

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

  defp fetch_registration_data(domain_name, ns_records) do
    sources = [
      {fn -> do_rdap_scan(domain_name) end, "rdap"},
      {fn -> do_whois_scan(domain_name) end, "whois"},
      {fn -> do_ns_heuristics(ns_records) end, "ns_heuristics"}
    ]

    Enum.find_value(sources, {%{}, "none"}, fn {scan_fn, source_name} ->
      case scan_fn.() do
        {:ok, result} -> {result, source_name}
        {:error, _} -> nil
      end
    end)
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
    entities = Map.get(body, "entities", [])

    registrar = parse_rdap_registrar(entities)
    contacts = parse_rdap_contacts(entities)

    registration_date = parse_rdap_date_from_body(body, "registration")
    expiration_date = parse_rdap_date_from_body(body, "expiration")

    if is_nil(registrar) && is_nil(registration_date) && is_nil(expiration_date) do
      {:error, "RDAP response had no useful data"}
    else
      {:ok,
       %{
         registrar: registrar,
         registration_date: registration_date,
         expiration_date: expiration_date,
         contacts: contacts
       }}
    end
  end

  defp parse_rdap_response(_), do: {:error, "Invalid RDAP response"}

  defp parse_rdap_registrar(entities) do
    Enum.find_value(entities, fn entity ->
      if "registrar" in Map.get(entity, "roles", []) do
        extract_vcard_value(get_in(entity, ["vcardArray", Access.at(1)]), "fn")
      end
    end)
  end

  defp parse_rdap_contacts(entities) do
    Enum.reduce(entities, %{}, fn entity, acc ->
      roles = Map.get(entity, "roles", [])
      vcard_data = get_in(entity, ["vcardArray", Access.at(1)]) || []

      contact_info =
        %{}
        |> put_vcard_val(vcard_data, "name", "fn")
        |> put_vcard_val(vcard_data, "email", "email")
        |> put_vcard_val(vcard_data, "phone", "tel")

      if map_size(contact_info) > 0 do
        Enum.reduce(roles, acc, &Map.put(&2, &1, contact_info))
      else
        acc
      end
    end)
  end

  defp put_vcard_val(map, vcard_data, key, vcard_key) do
    case extract_vcard_value(vcard_data, vcard_key) do
      nil -> map
      val -> Map.put(map, key, val)
    end
  end

  defp extract_vcard_value(nil, _), do: nil
  defp extract_vcard_value(vcard_data, key) do
    vcard_data
    |> List.wrap()
    |> Enum.find_value(fn
      [^key, _, _, val] -> val
      _ -> nil
    end)
  end

  defp parse_rdap_date_from_body(body, type) do
    key = if type == "registration", do: "registrationDate", else: "expirationDate"
    parse_rdap_date(
      Map.get(body, key) ||
        find_event_date(Map.get(body, "events"), type)
    )
  end

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
    case SystemCommand.run_with_timeout("whois", [domain_name], @whois_timeout) do
      {output, 0} ->
        result = parse_whois_output(output)

        if map_size(result) == 0 do
          {:error, "WHOIS returned no parseable data"}
        else
          {:ok, Map.put(result, :whois_raw, String.slice(output, 0, 4000))}
        end

      {:error, :timeout} ->
        {:error, "whois timed out after #{@whois_timeout}ms"}

      {:error, reason} ->
        {:error, reason}

      {_output, _code} ->
        {:error, "whois command failed"}
    end
  end

  defp parse_whois_output(output) do
    lines = String.split(output, "\n")
    Enum.reduce(lines, %{}, fn line, acc ->
      line |> String.trim() |> process_whois_line(acc)
    end)
  end

  defp process_whois_line(<<"Registrar:", _::binary>> = line, acc),
    do: Map.put_new(acc, :registrar, extract_whois_value(line))

  defp process_whois_line(<<"registrar:", _::binary>> = line, acc),
    do: Map.put_new(acc, :registrar, extract_whois_value(line))

  defp process_whois_line(<<"Registrant Organization:", _::binary>> = line, acc),
    do: Map.put_new(acc, :registrant_org, extract_whois_value(line))

  defp process_whois_line(<<"org:", _::binary>> = line, acc),
    do: Map.put_new(acc, :registrant_org, extract_whois_value(line))

  defp process_whois_line(<<"Organisation:", _::binary>> = line, acc),
    do: Map.put_new(acc, :registrant_org, extract_whois_value(line))

  defp process_whois_line(<<"Creation Date:", _::binary>> = line, acc),
    do: maybe_put_date(acc, :registration_date, line)

  defp process_whois_line(<<"created:", _::binary>> = line, acc),
    do: maybe_put_date(acc, :registration_date, line)

  defp process_whois_line(<<"Registered on:", _::binary>> = line, acc),
    do: maybe_put_date(acc, :registration_date, line)

  defp process_whois_line(<<"Registry Expiry Date:", _::binary>> = line, acc),
    do: maybe_put_date(acc, :expiration_date, line)

  defp process_whois_line(<<"Expiry date:", _::binary>> = line, acc),
    do: maybe_put_date(acc, :expiration_date, line)

  defp process_whois_line(<<"expire:", _::binary>> = line, acc),
    do: maybe_put_date(acc, :expiration_date, line)

  defp process_whois_line(<<"paid-till:", _::binary>> = line, acc),
    do: maybe_put_date(acc, :expiration_date, line)

  defp process_whois_line(_, acc), do: acc

  defp maybe_put_date(acc, key, line) do
    case parse_whois_date(extract_whois_value(line)) do
      nil -> acc
      dt -> Map.put_new(acc, key, dt)
    end
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

        Enum.find_value(ns_registrar_patterns(), fn {pattern, name} ->
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
    Ravner.Domains.DnsRecord
    |> where(domain_id: ^domain_id, type: "NS")
    |> select([r], r.value)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
  end
end
