defmodule Ravner.Scans.TlsHeaderAudit do
  @moduledoc """
  In-process TLS protocol and HTTP security headers auditor.

  Performs native security posture checks without external dependencies:
  1. **HTTP Security Headers**: Evaluates presence and strength of HSTS, CSP,
     X-Frame-Options (Clickjacking), X-Content-Type-Options, and identifies
     information-disclosing headers (`Server`, `X-Powered-By`).
  2. **Deprecated TLS Protocol Audit**: Uses Erlang's native `:ssl` module to
     attempt connections with obsolete TLS 1.0 and TLS 1.1 protocols.
  """

  require Logger

  @connect_timeout 2_500

  @type finding :: %{
          severity: String.t(),
          title: String.t(),
          target: String.t(),
          detail: map()
        }

  @doc """
  Runs the complete TLS and security headers audit for a domain.

  ## Parameters
  - `domain_name` - Target domain name (e.g. `"example.com"`)
  - `opts` - Keyword options:
    - `:headers` - pre-existing header map from an HTTP probe (optional)
    - `:final_url` - target URL (default: `"https://\#{domain_name}"`)
    - `:skip_tls` - boolean flag to skip raw TLS socket test (default: `false`)

  Returns `{:ok, [finding]}`.
  """
  @spec audit(String.t(), keyword()) :: {:ok, [finding()]}
  def audit(domain_name, opts \\ []) do
    target_url = Keyword.get(opts, :final_url, "https://#{domain_name}")
    raw_headers = Keyword.get(opts, :headers)
    skip_tls = Keyword.get(opts, :skip_tls, false)

    # 1. Audit HTTP security headers
    headers_map =
      case raw_headers do
        headers when is_map(headers) and map_size(headers) > 0 -> normalize_headers(headers)
        _ -> normalize_headers(fetch_headers(target_url))
      end

    header_findings = audit_headers(target_url, headers_map)

    # 2. Audit deprecated TLS protocols (TLS 1.0 / 1.1)
    tls_findings =
      if skip_tls do
        []
      else
        audit_tls_protocols(domain_name)
      end

    findings = header_findings ++ tls_findings

    has_hsts = Map.has_key?(headers_map, "strict-transport-security")
    has_csp = Map.has_key?(headers_map, "content-security-policy")
    has_x_frame = Map.has_key?(headers_map, "x-frame-options")
    deprecated_detected = Enum.any?(tls_findings, fn f -> f.severity in ["critical", "high"] end)

    # Emit standardized OpenTelemetry Security Headers telemetry
    Ravner.Telemetry.Synthetic.emit_security_headers(
      %{
        findings_count: length(findings),
        hsts_present: if(has_hsts, do: 1, else: 0),
        csp_present: if(has_csp, do: 1, else: 0),
        x_frame_present: if(has_x_frame, do: 1, else: 0)
      },
      %{
        "server.address" => domain_name,
        "url.full" => target_url,
        "security.deprecated_tls_detected" => deprecated_detected
      }
    )

    {:ok, findings}
  rescue
    e in [ArgumentError, RuntimeError, Req.TransportError, Mint.TransportError] ->
      Logger.warning("TLS & headers audit failed for #{domain_name}: #{inspect(e)}")
      {:ok, []}
  end

  # ─── Headers Audit ─────────────────────────────────────────────────────────

  @doc """
  Audits a map of normalized (lowercased) HTTP headers against security baselines.
  """
  @spec audit_headers(String.t(), map()) :: [finding()]
  def audit_headers(target_url, headers) when is_map(headers) do
    findings = []

    # Check HSTS (Strict-Transport-Security)
    findings =
      case Map.get(headers, "strict-transport-security") do
        nil ->
          if String.starts_with?(target_url, "https://") do
            [
              %{
                severity: "medium",
                title: "Missing HTTP Strict Transport Security (HSTS)",
                target: target_url,
                detail: %{
                  "source" => "headers_audit",
                  "header" => "Strict-Transport-Security",
                  "description" =>
                    "HSTS is not configured. Browsers may establish unencrypted HTTP connections, allowing SSL stripping and man-in-the-middle attacks.",
                  "remediation" =>
                    "Add 'Strict-Transport-Security: max-age=31536000; includeSubDomains; preload' to all HTTPS responses.",
                  "references" => [
                    "https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Strict-Transport-Security",
                    "https://hstspreload.org/"
                  ]
                }
              }
              | findings
            ]
          else
            findings
          end

        hsts_val ->
          hsts_str = to_string(hsts_val)

          case Regex.run(~r/max-age\s*=\s*(\d+)/i, hsts_str) do
            [_, max_age_str] ->
              max_age = String.to_integer(max_age_str)

              if max_age < 15_552_000 do
                [
                  %{
                    severity: "low",
                    title: "Short HSTS max-age Duration (< 180 days)",
                    target: target_url,
                    detail: %{
                      "source" => "headers_audit",
                      "header" => "Strict-Transport-Security",
                      "value" => hsts_str,
                      "description" =>
                        "The HSTS max-age duration is #{max_age} seconds (less than 180 days), which provides insufficient protection against downgrade attacks.",
                      "remediation" =>
                        "Increase max-age to at least 31536000 (1 year) to meet modern security standards.",
                      "references" => [
                        "https://hstspreload.org/"
                      ]
                    }
                  }
                  | findings
                ]
              else
                findings
              end

            _ ->
              findings
          end
      end

    # Check Content-Security-Policy (CSP)
    findings =
      case Map.get(headers, "content-security-policy") do
        nil ->
          [
            %{
              severity: "low",
              title: "Missing Content Security Policy (CSP)",
              target: target_url,
              detail: %{
                "source" => "headers_audit",
                "header" => "Content-Security-Policy",
                "description" =>
                  "Content-Security-Policy header is missing, increasing vulnerability to Cross-Site Scripting (XSS) and data injection attacks.",
                "remediation" =>
                  "Configure a Content-Security-Policy restricting unauthorized script, object, and style sources.",
                "references" => [
                  "https://developer.mozilla.org/en-US/docs/Web/HTTP/CSP",
                  "https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html"
                ]
              }
            }
            | findings
          ]

        _ ->
          findings
      end

    # Check Clickjacking: X-Frame-Options or CSP frame-ancestors
    csp = to_string(Map.get(headers, "content-security-policy", ""))
    has_frame_ancestors = String.contains?(String.downcase(csp), "frame-ancestors")
    x_frame = Map.get(headers, "x-frame-options")

    findings =
      if is_nil(x_frame) and not has_frame_ancestors do
        [
          %{
            severity: "medium",
            title: "Missing Clickjacking Protection (X-Frame-Options)",
            target: target_url,
            detail: %{
              "source" => "headers_audit",
              "header" => "X-Frame-Options",
              "description" =>
                "Neither X-Frame-Options nor CSP frame-ancestors is present. Malicious websites can embed this application into an iframe to execute clickjacking attacks.",
              "remediation" =>
                "Set 'X-Frame-Options: SAMEORIGIN' or configure 'Content-Security-Policy: frame-ancestors 'self''.",
              "references" => [
                "https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/X-Frame-Options",
                "https://owasp.org/www-community/attacks/Clickjacking"
              ]
            }
          }
          | findings
        ]
      else
        findings
      end

    # Check X-Content-Type-Options: nosniff
    x_content_type = Map.get(headers, "x-content-type-options")

    findings =
      if is_nil(x_content_type) or
           not String.contains?(String.downcase(to_string(x_content_type)), "nosniff") do
        [
          %{
            severity: "low",
            title: "Missing X-Content-Type-Options: nosniff",
            target: target_url,
            detail: %{
              "source" => "headers_audit",
              "header" => "X-Content-Type-Options",
              "description" =>
                "The X-Content-Type-Options: nosniff header is missing. Browsers may MIME-sniff response content away from the declared content-type.",
              "remediation" => "Add 'X-Content-Type-Options: nosniff' to all HTTP responses.",
              "references" => [
                "https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/X-Content-Type-Options"
              ]
            }
          }
          | findings
        ]
      else
        findings
      end

    # Check Information Disclosure: Server header with detailed version numbers
    server_header = to_string(Map.get(headers, "server", ""))

    findings =
      if Regex.match?(~r/(?:Apache|nginx|IIS|LiteSpeed|OpenSSL|PHP)\/[\d\.]+/i, server_header) do
        [
          %{
            severity: "info",
            title: "Server Version Information Disclosure",
            target: target_url,
            detail: %{
              "source" => "headers_audit",
              "header" => "Server",
              "value" => server_header,
              "description" =>
                "The Server header discloses precise software version details (#{server_header}), assisting attackers in identifying known CVEs.",
              "remediation" =>
                "Configure web server tokens (e.g. 'ServerTokens Prod' in Apache, 'server_tokens off;' in Nginx) to suppress version disclosure.",
              "references" => [
                "https://owasp.org/www-project-web-security-testing-guide/latest/4-web-application-security-testing/01-information-gathering/02-fingerprint-web-server"
              ]
            }
          }
          | findings
        ]
      else
        findings
      end

    # Check Information Disclosure: X-Powered-By header
    x_powered_by = Map.get(headers, "x-powered-by")

    findings =
      if x_powered_by && to_string(x_powered_by) != "" do
        [
          %{
            severity: "low",
            title: "X-Powered-By Header Discloses Technology",
            target: target_url,
            detail: %{
              "source" => "headers_audit",
              "header" => "X-Powered-By",
              "value" => to_string(x_powered_by),
              "description" =>
                "The X-Powered-By header reveals underlying framework or runtime components (#{to_string(x_powered_by)}).",
              "remediation" =>
                "Disable the X-Powered-By response header in your framework configuration.",
              "references" => [
                "https://owasp.org/www-project-web-security-testing-guide/latest/4-web-application-security-testing/01-information-gathering/08-fingerprint-web-application-framework"
              ]
            }
          }
          | findings
        ]
      else
        findings
      end

    findings
  end

  # ─── TLS Protocols Audit ───────────────────────────────────────────────────

  @doc """
  Audits a target host for acceptance of deprecated TLS 1.0 or TLS 1.1 protocols.
  """
  @spec audit_tls_protocols(String.t(), integer()) :: [finding()]
  def audit_tls_protocols(domain_name, port \\ 443) do
    host = to_charlist(domain_name)

    # Attempt connection forcing deprecated TLS versions (TLS 1.0 and 1.1)
    opts = [
      active: false,
      verify: :verify_none,
      packet: :raw,
      mode: :binary,
      versions: [:tlsv1, :"tlsv1.1"],
      server_name_indication: host
    ]

    case :ssl.connect(host, port, opts, @connect_timeout) do
      {:ok, socket} ->
        protocol_version =
          case :ssl.connection_information(socket, [:protocol]) do
            {:ok, [protocol: proto]} -> to_string(proto)
            _ -> "TLS 1.0/1.1"
          end

        :ssl.close(socket)

        [
          %{
            severity: "high",
            title: "Deprecated TLS Protocol Supported (#{protocol_version})",
            target: "#{domain_name}:#{port}",
            detail: %{
              "source" => "tls_audit",
              "protocol" => protocol_version,
              "port" => port,
              "description" =>
                "The server successfully negotiated a connection using #{protocol_version}. Obsolete TLS 1.0 and 1.1 protocols have cryptographic weaknesses (BEAST, POODLE) and violate PCI-DSS compliance requirements.",
              "remediation" =>
                "Disable TLS 1.0 and TLS 1.1 on your web server / load balancer. Enforce TLS 1.2 or TLS 1.3 as the minimum acceptable protocol.",
              "references" => [
                "https://datatracker.ietf.org/doc/rfc8996/",
                "https://csrc.nist.gov/pubs/sp/800/52/r2/final"
              ]
            }
          }
        ]

      _ ->
        []
    end
  rescue
    _e in [ArgumentError, ErlangError] -> []
  end

  # ─── Helpers ───────────────────────────────────────────────────────────────

  defp fetch_headers(url) do
    case Req.head(url, receive_timeout: 2_000, redirect: true) do
      {:ok, %Req.Response{headers: headers}} -> headers
      _ -> %{}
    end
  rescue
    _e in [Req.TransportError, Mint.TransportError, ArgumentError] -> %{}
  end

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {k, v} ->
      val_str =
        cond do
          is_list(v) -> Enum.join(v, ", ")
          is_binary(v) -> v
          true -> to_string(v)
        end

      {String.downcase(to_string(k)), val_str}
    end)
  end

  defp normalize_headers(_), do: %{}
end
