defmodule Ravner.Scans.Dns do
  @moduledoc """
  DNS resolution using dnsx.
  """

  alias Ravner.Domains
  alias Ravner.SystemCommand

  @dnsx_timeout 30_000

  @spec run(integer()) :: {:ok, map()} | {:error, term()}
  def run(domain_id) do
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
          scanned_at: DateTime.utc_now(),
          dns_scanned_at: DateTime.utc_now()
        }

        Domains.upsert_domain_metadata(domain_id, meta)
        Domains.sync_dns_records(domain_id, records)
        {:ok, Map.put(meta, :dns_records, records)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_dnsx_scan(domain_name) do
    tmp_path =
      Path.join(System.tmp_dir!(), "ravner_dnsx_#{System.unique_integer([:positive])}.txt")

    File.write!(tmp_path, domain_name <> "\n")

    args = ["-l", tmp_path, "-a", "-aaaa", "-cname", "-mx", "-ns", "-txt", "-json", "-silent"]

    try do
      SystemCommand.run_with_timeout("dnsx", args, @dnsx_timeout)
      |> handle_dnsx_output()
    after
      File.rm(tmp_path)
    end
  end

  defp handle_dnsx_output({output, 0}) do
    case String.trim(output) do
      "" -> {:ok, %{}}
      trimmed -> parse_json(trimmed)
    end
  end

  defp handle_dnsx_output({:error, :timeout}),
    do: {:error, "dnsx timed out after #{@dnsx_timeout}ms"}

  defp handle_dnsx_output({:error, reason}), do: {:error, reason}

  defp handle_dnsx_output({output, code}),
    do: {:error, "dnsx failed (exit #{code}): #{String.slice(output, 0, 200)}"}

  defp parse_json(json) do
    case Jason.decode(json) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, "Failed to parse dnsx output"}
    end
  end
end
