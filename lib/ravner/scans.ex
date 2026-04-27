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
end
