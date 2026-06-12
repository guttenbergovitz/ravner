defmodule Ravner.Scans do
  @moduledoc """
  The Scans context.
  """

  require Logger

  import Ecto.Query

  alias Ravner.ApiKeys
  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Repo

  @two_part_tlds ~w(co.uk com.au co.nz co.za com.br co.in org.uk me.uk net.uk co.jp)

  @doc """
  Returns true when `final_url` points to a different apex domain than `domain_name`.
  """
  @spec external_redirect?(String.t(), String.t() | nil) :: boolean()
  def external_redirect?(_domain_name, nil), do: false

  def external_redirect?(domain_name, final_url) when is_binary(final_url) do
    current_root = extract_root_domain(domain_name)

    final_root =
      final_url
      |> URI.parse()
      |> Map.get(:host)
      |> Kernel.||("")
      |> extract_root_domain()

    final_root != "" && final_root != current_root
  end

  defp extract_root_domain(host) when is_binary(host) do
    parts = host |> String.replace_prefix("www.", "") |> String.split(".")
    count = length(parts)

    cond do
      count >= 3 && Enum.join(Enum.take(parts, -2), ".") in @two_part_tlds ->
        parts |> Enum.take(-3) |> Enum.join(".")

      count >= 2 ->
        parts |> Enum.take(-2) |> Enum.join(".")

      true ->
        host
    end
  end

  defp extract_root_domain(_), do: ""

  @chaos_api "https://dns.projectdiscovery.io"
  @hackertarget_api "https://api.hackertarget.com/hostsearch"
  @crtsh_api "https://crt.sh"

  @spec run_quick_scan(integer()) :: %{atom() => {:ok, term()} | {:error, term()}}
  def run_quick_scan(domain_id) do
    domain = Domains.get_domain!(domain_id)
    dnsx = Ravner.Scans.Dns.run(domain_id)

    if dns_scan_allows_network_steps?(dnsx) do
      rdap_task = Task.async(fn -> Ravner.Scans.Whois.run_rdap_scan(domain_id) end)
      httpx = Ravner.Scans.Http.run_httpx_scan(domain_id)
      rdap = Task.await(rdap_task, :infinity)

      subdomains =
        if httpx_is_external_redirect?(domain.name, httpx),
          do: {:error, :external_redirect},
          else: maybe_run_subdomain_scan(domain)

      %{dnsx: dnsx, httpx: httpx, rdap: rdap, subdomains: subdomains}
    else
      skipped = mark_unreachable_after_dns(domain)

      %{
        dnsx: dnsx,
        httpx: skipped,
        rdap: skipped,
        subdomains: skipped
      }
    end
  end

  defp httpx_is_external_redirect?(domain_name, {:ok, %{final_url: final_url}}),
    do: external_redirect?(domain_name, final_url)

  defp httpx_is_external_redirect?(_domain_name, _httpx_result), do: false

  defp maybe_run_subdomain_scan(%Domain{type: :domain, id: id}), do: run_subdomain_scan(id)

  defp maybe_run_subdomain_scan(%Domain{type: :subdomain}) do
    {:error, "Subdomain scan only supported for apex domains"}
  end

  defp dns_scan_allows_network_steps?({:ok, metadata}) do
    metadata_has_ips?(metadata)
  end

  defp dns_scan_allows_network_steps?({:error, reason}) when is_binary(reason) do
    String.contains?(reason, "executable not found")
  end

  defp dns_scan_allows_network_steps?(_), do: false

  defp metadata_has_ips?(%{ip_v4: ip_v4, ip_v6: ip_v6}) do
    ip_v4 != [] or ip_v6 != []
  end

  defp metadata_has_ips?(_), do: false

  defp mark_unreachable_after_dns(domain) do
    now = DateTime.utc_now()

    Domains.upsert_domain_metadata(domain.id, %{
      http_status: 0,
      scanned_at: now,
      http_scanned_at: now
    })

    Domains.record_technical_status(domain, :error)

    {:error, :dns_unresolved}
  end

  @spec scan_max_concurrency() :: pos_integer()
  def scan_max_concurrency do
    case Application.get_env(:ravner, :scan_max_concurrency, 5) do
      value when is_integer(value) and value > 0 -> value
      _ -> 5
    end
  end

  @doc """
  Runs a subdomain discovery scan for a domain.

  Tries Chaos API first, falls back to HackerTarget if Chaos fails or no key.
  """
  @spec run_subdomain_scan(integer()) :: {:ok, map()} | {:error, String.t()}
  def run_subdomain_scan(domain_id) do
    domain = Domains.get_domain!(domain_id)

    # Subdomain discovery only makes sense for apex domains
    if domain.parent_domain_id != nil do
      Logger.info("Skipping subdomain scan for non-apex domain #{domain.name}")
      {:error, "Subdomain scan only supported for apex domains"}
    else
      Ravner.ActivityLog.emit(:step, "Discovering subdomains for #{domain.name}…")
      result = run_subdomain_sources(domain.name, domain.id)

      case result do
        {:ok, data} ->
          Domains.upsert_domain_metadata(domain_id, %{subdomains_scanned_at: DateTime.utc_now()})

          Ravner.ActivityLog.emit(
            :done,
            "Subdomains done — #{data.found} found for #{domain.name}"
          )

          {:ok, data}

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
    case get_chaos_api_key() do
      nil ->
        {:error,
         "No Chaos API key configured (add in Settings > API Keys or set CHAOS_API_KEY env var)"}

      api_key ->
        execute_chaos_request(domain_name, api_key)
    end
  end

  defp get_chaos_api_key do
    case ApiKeys.get_effective_key("chaos") do
      {:settings, _, _} -> System.get_env("CHAOS_API_KEY")
      {:env, key, _} -> key
      {:none, _, _} -> nil
    end
  end

  defp execute_chaos_request(domain_name, api_key) do
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

  defp run_hackertarget(domain_name) do
    case Req.get("#{@hackertarget_api}/?q=#{domain_name}",
           retry: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        parse_hackertarget_response(body, domain_name)

      {:ok, %{status: status}} ->
        {:error, "HackerTarget returned #{status}"}

      {:error, exception} ->
        {:error, "HackerTarget request failed: #{inspect(exception)}"}
    end
  end

  defp parse_hackertarget_response(body, domain_name) do
    if is_binary(body) and
         (body =~ "API count exceeded" or body =~ "error check your" or
            body =~ "invalid host") do
      Logger.warning("HackerTarget quota/error for #{domain_name}: #{String.slice(body, 0, 100)}")

      {:error, "HackerTarget: #{String.trim(body)}"}
    else
      subdomains =
        body
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
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
  end

  defp run_crtsh(domain_name) do
    case Req.get("#{@crtsh_api}/?q=%25.#{domain_name}&output=json",
           retry: false,
           receive_timeout: 8_000
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

        {:ok, subdomains}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Logger.warning(
          "crt.sh unexpected text body for #{domain_name}: #{String.slice(body, 0, 100)}"
        )

        {:error, "crt.sh returned unexpected response"}

      {:ok, %{status: status}} ->
        {:error, "crt.sh returned #{status}"}

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.info("crt.sh timed out for #{domain_name}, treating as no results")
        {:ok, []}

      {:error, exception} ->
        Logger.warning("crt.sh request failed for #{domain_name}: #{inspect(exception)}")
        {:error, "crt.sh request failed: #{inspect(exception)}"}
    end
  end

  defp save_subdomains(subdomains, parent_id) do
    domain = Domains.get_domain!(parent_id)
    names = filter_subdomain_names(subdomains, domain.name)
    existing = get_existing_domains(names)

    {inserted_count, new_domains} =
      names
      |> Enum.reject(&Map.has_key?(existing, &1))
      |> insert_new_subdomains(parent_id)

    relink_existing_subdomains(existing, parent_id)

    all_results = new_domains ++ Enum.map(existing, fn {_name, {id, _pid}} -> %Domain{id: id} end)

    {:ok, %{found: length(names), new: inserted_count, subdomains: all_results}}
  end

  defp filter_subdomain_names(names, domain_name) do
    names
    |> Enum.map(fn subdomain_name ->
      if String.ends_with?(subdomain_name, ".#{domain_name}") || subdomain_name == domain_name do
        subdomain_name
      else
        "#{subdomain_name}.#{domain_name}"
      end
    end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == domain_name or &1 == ""))
  end

  defp get_existing_domains(names) do
    Domain
    |> where([d], d.name in ^names)
    |> select([d], {d.name, d.id, d.parent_domain_id})
    |> Repo.all()
    |> Map.new(fn {name, id, pid} -> {name, {id, pid}} end)
  end

  defp insert_new_subdomains([], _parent_id), do: {0, []}

  defp insert_new_subdomains(names, parent_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(names, fn name ->
        %{
          name: name,
          type: :subdomain,
          lifecycle_state: :under_review,
          parent_domain_id: parent_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(Domain, entries,
        conflict: :nothing,
        returning: [:id, :name, :type, :lifecycle_state, :parent_domain_id]
      )

    {count, Enum.map(entries, &struct(Domain, &1))}
  end

  defp relink_existing_subdomains(existing, parent_id) do
    ids_to_relink =
      existing
      |> Enum.filter(fn {_name, {_id, pid}} -> pid != parent_id end)
      |> Enum.map(fn {_name, {id, _pid}} -> id end)

    case ids_to_relink do
      [] ->
        :ok

      ids ->
        {_count, _} =
          Domain
          |> where([d], d.id in ^ids)
          |> Repo.update_all(
            set: [parent_domain_id: parent_id, updated_at: DateTime.utc_now(:second)]
          )

        :ok
    end
  end

  # HTTPX scan via Req (fast, non-blocking)

  # ---------------------------------------------------------------------------
  # RDAP / WHOIS / NS-heuristics scan
  # Fallback chain: RDAP HTTP → WHOIS CLI → NS heuristics (from stored DNS data)
  # ---------------------------------------------------------------------------
end
