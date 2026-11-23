defmodule Ravner.Scans.Dns do
  @moduledoc """
  Native DNS resolution using Erlang's `:inet_res` (no external binaries).
  """

  require Logger

  alias Ravner.Domains

  @dns_timeout 5_000
  @record_types [:a, :aaaa, :cname, :mx, :ns, :txt]

  @type dns_error :: :nxdomain | :timeout | :servfail | {:network, term()}

  @spec run(integer()) :: {:ok, map()} | {:error, dns_error()}
  def run(domain_id) do
    domain = Domains.get_domain!(domain_id)
    Ravner.ActivityLog.emit(:step, "Resolving DNS for #{domain.name}…")

    started_at = System.monotonic_time(:millisecond)

    case do_dns_scan(domain.name) do
      {:ok, data} ->
        elapsed = System.monotonic_time(:millisecond) - started_at

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

        # Emit standardized OpenTelemetry DNS telemetry
        has_spf =
          Enum.any?(records, fn r ->
            r.type == "TXT" and String.starts_with?(r.value, "v=spf1")
          end)

        has_mx = Enum.any?(records, fn r -> r.type == "MX" end)

        Ravner.Telemetry.Synthetic.emit_dns_audit(
          %{
            duration_ms: elapsed,
            record_count: length(records),
            spf_valid: if(has_spf, do: 1, else: 0),
            has_mx: if(has_mx, do: 1, else: 0)
          },
          %{
            "server.address" => domain.name,
            "ravner.domain_id" => domain_id
          }
        )

        Ravner.ActivityLog.emit(:done, "DNS done — #{length(records)} records for #{domain.name}")
        {:ok, Map.put(meta, :dns_records, records)}

      {:error, :nxdomain} ->
        Logger.info("DNS NXDOMAIN for #{domain.name}")
        Ravner.ActivityLog.emit(:error, "DNS — domain #{domain.name} does not exist (NXDOMAIN)")
        {:error, :nxdomain}

      {:error, :timeout} ->
        Logger.warning("DNS timeout for #{domain.name}")
        Ravner.ActivityLog.emit(:error, "DNS — query timed out for #{domain.name}")
        {:error, :timeout}

      {:error, :servfail} ->
        Logger.warning("DNS SERVFAIL for #{domain.name}")
        Ravner.ActivityLog.emit(:error, "DNS — server failure for #{domain.name}")
        {:error, :servfail}

      {:error, reason} ->
        Logger.warning("DNS error for #{domain.name}: #{inspect(reason)}")
        Ravner.ActivityLog.emit(:error, "DNS — error for #{domain.name}: #{inspect(reason)}")
        {:error, {:network, reason}}
    end
  end

  defp do_dns_scan(domain_name) do
    name = String.to_charlist(domain_name)

    # First check if domain exists by resolving A record with proper error handling
    case resolve_with_error(name, :a) do
      {:error, reason} when reason in [:nxdomain, :timeout, :servfail] ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:network, reason}}

      {:ok, _} ->
        # Domain exists, gather all record types
        data =
          @record_types
          |> Map.new(fn type ->
            values =
              name
              |> lookup(type)
              |> Enum.map(&format_record(type, &1))

            {Atom.to_string(type), values}
          end)
          |> Map.reject(fn {_type, values} -> values == [] end)

        case resolve_ttl(name) do
          nil -> {:ok, data}
          ttl -> {:ok, Map.put(data, "ttl", ttl)}
        end
    end
  end

  # Use resolve instead of lookup to get proper error typing
  defp resolve_with_error(name, type) do
    case :inet_res.resolve(name, :in, type, [], @dns_timeout) do
      {:ok, _msg} -> {:ok, :exists}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _e in [ArgumentError, ErlangError] -> {:error, :unknown}
  end

  defp lookup(name, type) do
    :inet_res.lookup(name, :in, type, [], @dns_timeout)
  rescue
    _e in [ArgumentError, ErlangError] -> []
  end

  # Best-effort TTL from the A record answers (the UI stores a single TTL per
  # scan, same as dnsx did).
  defp resolve_ttl(name) do
    with {:ok, msg} <- :inet_res.resolve(name, :in, :a, [], @dns_timeout),
         [answer | _] <- :inet_dns.msg(msg, :anlist) do
      :inet_dns.rr(answer, :ttl)
    else
      _ -> nil
    end
  rescue
    _e in [ArgumentError, ErlangError] -> nil
  end

  @doc false
  def format_record(type, record)

  def format_record(:a, record), do: record |> :inet.ntoa() |> to_string()
  def format_record(:aaaa, record), do: record |> :inet.ntoa() |> to_string()
  def format_record(:mx, {preference, host}), do: "#{preference} #{host}"
  def format_record(:txt, segments) when is_list(segments), do: IO.iodata_to_binary(segments)
  def format_record(type, record) when type in [:ns, :cname], do: to_string(record)
end
