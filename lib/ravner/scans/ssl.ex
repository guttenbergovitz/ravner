defmodule Ravner.Scans.Ssl do
  @moduledoc """
  SSL/TLS certificate scanning and ASN.1 certificate parsing.

  Connects to port 443 with SNI enabled and extracts issuer, subject,
  and validity window from the leaf certificate. Used both as a top-level
  scan (`run/1`) and as inline enrichment after an HTTP scan (`enrich/3`).
  """

  require Logger

  alias Ravner.Domains

  @connect_timeout 5_000

  @doc """
  Runs an SSL scan for the given `domain_id` and persists the result via
  `Ravner.Domains.upsert_domain_metadata/2`.
  """
  @spec run(integer()) :: {:ok, map()} | {:error, term()}
  def run(domain_id) do
    domain = Domains.get_domain!(domain_id)

    case scan(domain.name) do
      {:ok, data} ->
        Domains.upsert_domain_metadata(domain_id, data)
        {:ok, data}

      error ->
        error
    end
  end

  @doc """
  Merges SSL data into the given metadata map. Failures are silently dropped
  so that an HTTPX scan is not penalised by an unrelated SSL error.
  """
  @spec enrich(map(), String.t(), String.t() | nil) :: map()
  def enrich(meta, domain_name, _final_url) do
    case scan(domain_name) do
      {:ok, ssl_data} -> Map.merge(meta, ssl_data)
      _ -> meta
    end
  end

  @doc """
  Connects to `domain_name:443` and decodes the leaf certificate. Returns
  `{:ok, ssl_metadata}` or `{:error, reason}`.
  """
  @spec scan(String.t()) :: {:ok, map()} | {:error, term()}
  def scan(domain_name) do
    host = to_charlist(domain_name)

    opts = [
      active: false,
      verify: :verify_none,
      packet: :raw,
      mode: :binary,
      server_name_indication: host
    ]

    case :ssl.connect(host, 443, opts, @connect_timeout) do
      {:ok, socket} ->
        result =
          case :ssl.peercert(socket) do
            {:ok, cert} -> parse_cert(cert)
            error -> error
          end

        :ssl.close(socket)
        result

      error ->
        error
    end
  end

  defp parse_cert(cert) do
    # Decode the certificate using OTP records.
    # OTPTBSCertificate record structure (0-indexed):
    #   0: :OTPTBSCertificate
    #   1: version
    #   2: serialNumber
    #   3: signature
    #   4: issuer
    #   5: validity
    #   6: subject
    decoded = :public_key.pkix_decode_cert(cert, :otp)
    tbs = elem(decoded, 1)

    validity = elem(tbs, 5)
    {_tag_before, not_before} = elem(validity, 1)
    {_tag_after, not_after} = elem(validity, 2)

    valid_from = parse_asn1_time(not_before)
    valid_until = parse_asn1_time(not_after)

    issuer = decode_rdn_sequence(elem(tbs, 4))
    subject = decode_rdn_sequence(elem(tbs, 6))

    days_remaining =
      if valid_until do
        DateTime.diff(valid_until, DateTime.utc_now(), :day)
      end

    {:ok,
     %{
       ssl_issuer: issuer,
       ssl_subject: subject,
       ssl_valid_from: valid_from,
       ssl_valid_until: valid_until,
       ssl_days_remaining: days_remaining
     }}
  rescue
    e ->
      Logger.warning("Failed to parse SSL certificate: #{inspect(e)}")
      {:error, :parse_failed}
  end

  # ── ASN.1 time decoding ─────────────────────────────────────────────────────

  defp parse_asn1_time(time_str) do
    str = to_string(time_str)

    case String.length(str) do
      13 ->
        year_short = str |> String.slice(0, 2) |> String.to_integer()
        year = if year_short >= 50, do: 1900 + year_short, else: 2000 + year_short
        rest = String.slice(str, 2, 10)
        parse_iso("#{year}#{rest}")

      15 ->
        parse_iso(String.slice(str, 0, 14))

      _ ->
        nil
    end
  end

  defp parse_iso(str) do
    case Regex.run(~r/(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/, str) do
      [_, y, m, d, hh, mm, ss] ->
        "#{y}-#{m}-#{d}T#{hh}:#{mm}:#{ss}Z" |> DateTime.from_iso8601() |> elem(1)

      _ ->
        nil
    end
  end

  # ── RDN / OID decoding ──────────────────────────────────────────────────────

  defp decode_rdn_sequence({:rdnSequence, list}), do: decode_rdn_list(list)
  defp decode_rdn_sequence(list) when is_list(list), do: decode_rdn_list(list)
  defp decode_rdn_sequence(_), do: "unknown"

  defp decode_rdn_list(list) do
    Enum.map_join(list, ", ", fn
      rdn_set when is_list(rdn_set) ->
        Enum.map_join(rdn_set, "+", fn rdn ->
          # AttributeTypeAndValue record
          type_oid = elem(rdn, 1)
          value = decode_asn1_string(elem(rdn, 2))
          type_label = decode_oid(type_oid)
          "#{type_label}=#{value}"
        end)

      _ ->
        "unknown"
    end)
  end

  defp decode_asn1_string({:utf8String, s}), do: to_string(s)
  defp decode_asn1_string({:printableString, s}), do: to_string(s)
  defp decode_asn1_string({:teletexString, s}), do: to_string(s)
  defp decode_asn1_string({:ia5String, s}), do: to_string(s)
  defp decode_asn1_string(s) when is_binary(s), do: s
  defp decode_asn1_string(s), do: inspect(s)

  defp decode_oid({2, 5, 4, 3}), do: "CN"
  defp decode_oid({2, 5, 4, 10}), do: "O"
  defp decode_oid({2, 5, 4, 11}), do: "OU"
  defp decode_oid({2, 5, 4, 6}), do: "C"
  defp decode_oid({2, 5, 4, 7}), do: "L"
  defp decode_oid({2, 5, 4, 8}), do: "ST"
  defp decode_oid(oid), do: inspect(oid)
end
