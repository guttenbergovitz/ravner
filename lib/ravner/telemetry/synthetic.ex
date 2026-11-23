defmodule Ravner.Telemetry.Synthetic do
  @moduledoc """
  Telemetry facade for emitting synthetic domain, network, and vulnerability measurements
  following Cloud Native Computing Foundation (CNCF) OpenTelemetry Semantic Conventions.

  Every call executes `:telemetry.execute/3`, pushes the event into `Ravner.Telemetry.EventBuffer`,
  and broadcasts it to Phoenix PubSub topic `"telemetry:synthetic"` for real-time LiveView streaming.
  """

  alias Ravner.Telemetry.EventBuffer

  @pubsub_topic "telemetry:synthetic"

  # ── Public Emission APIs ───────────────────────────────────────────────────

  @doc """
  Emits a synthetic HTTP/heartbeat probe event `[:ravner, :synthetic, :http, :stop]`.

  ## Measurements
  * `duration_ms` (integer): Total round-trip time in milliseconds.
  * `response_time_ms` (integer | nil): Time to first byte if successful.

  ## Metadata (OTel SemConv)
  * `"server.address"` (string): Target hostname (e.g. `"example.com"`).
  * `"url.full"` (string): Complete target URL probed.
  * `"http.request.method"` (string): `"HEAD"`, `"GET"`.
  * `"http.response.status_code"` (integer | nil): e.g. `200`, `404`, `502`.
  * `"error.type"` (string | nil): `"timeout"`, `"econnrefused"`, `"nxdomain"`, `"ssl_error"`.
  * `"ravner.domain_id"` (integer | nil): Domain ID if attached.
  """
  @spec emit_http_probe(map(), map()) :: :ok
  def emit_http_probe(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    record_and_broadcast([:ravner, :synthetic, :http, :stop], :http, measurements, metadata)
  end

  @doc """
  Emits a Software Composition Analysis (SCA) repository scan event `[:ravner, :synthetic, :sca, :stop]`.

  ## Measurements
  * `duration_ms` (integer): Time spent analyzing manifest and querying OSV.dev.
  * `vulnerability_count` (integer): Total detected vulnerabilities.
  * `critical_count` (integer): Vulnerabilities with severity `CRITICAL`.
  * `high_count` (integer): Vulnerabilities with severity `HIGH`.

  ## Metadata (OTel SemConv)
  * `"vcs.provider"` (string): `"bitbucket"`, `"github"`, `"gitlab"`.
  * `"vcs.repository.name"` (string): Repository slug.
  * `"vcs.repository.url"` (string): Full repository URL.
  * `"ravner.project_id"` (integer | nil): Associated project ID.
  * `"ravner.domain_id"` (integer | nil): Associated domain ID.
  """
  @spec emit_sca_scan(map(), map()) :: :ok
  def emit_sca_scan(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    record_and_broadcast([:ravner, :synthetic, :sca, :stop], :sca, measurements, metadata)
  end

  @doc """
  Emits a Secrets Detection repository scan event `[:ravner, :synthetic, :secrets, :stop]`.

  ## Measurements
  * `duration_ms` (integer): Time spent scanning files.
  * `secrets_count` (integer): Total detected secrets.
  * `critical_count` (integer): Secrets with severity `critical`.
  * `high_count` (integer): Secrets with severity `high`.

  ## Metadata (OTel SemConv)
  * `"vcs.provider"` (string): `"bitbucket"`, `"github"`, `"gitlab"`.
  * `"vcs.repository.name"` (string): Repository slug.
  * `"vcs.repository.url"` (string): Full repository URL.
  * `"ravner.project_id"` (integer | nil): Associated project ID.
  * `"ravner.domain_id"` (integer | nil): Associated domain ID.
  """
  @spec emit_secrets_scan(map(), map()) :: :ok
  def emit_secrets_scan(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    record_and_broadcast([:ravner, :synthetic, :secrets, :stop], :secrets, measurements, metadata)
  end

  @doc """
  Emits a TLS / SSL certificate check event `[:ravner, :synthetic, :tls, :stop]`.

  ## Measurements
  * `days_until_expiry` (integer): Days until certificate expiration.
  * `handshake_ms` (integer): Handshake duration in milliseconds.

  ## Metadata (OTel SemConv)
  * `"server.address"` (string): Hostname.
  * `"tls.protocol.version"` (string): e.g. `"TLSv1.3"`, `"TLSv1.2"`, `"TLSv1.0"`.
  * `"tls.cipher"` (string): Negotiated cipher suite.
  * `"tls.status"` (atom | string): `:valid`, `:expired`, `:untrusted`.
  """
  @spec emit_tls_probe(map(), map()) :: :ok
  def emit_tls_probe(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    record_and_broadcast([:ravner, :synthetic, :tls, :stop], :tls, measurements, metadata)
  end

  @doc """
  Emits a native vulnerability or sensitive path probe event `[:ravner, :synthetic, :probe, :stop]`.

  ## Measurements
  * `duration_ms` (integer): Execution duration in milliseconds.
  * `matches_count` (integer): Number of positive findings discovered.

  ## Metadata (OTel SemConv)
  * `"server.address"` (string): Hostname.
  * `"probe.category"` (string): `"secret_leak"`, `"exposed_panel"`, `"cve_signature"`.
  * `"probe.name"` (string): Specific signature name.
  """
  @spec emit_native_probe(map(), map()) :: :ok
  def emit_native_probe(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    record_and_broadcast([:ravner, :synthetic, :probe, :stop], :probe, measurements, metadata)
  end

  @doc """
  Emits an uptime availability status probe event `[:ravner, :synthetic, :uptime, :status]`.

  ## Measurements
  * `status` (integer): `1` for up, `0` for down.
  * `response_time_ms` (integer): Measured response time in milliseconds.

  ## Metadata (OTel SemConv)
  * `"server.address"` (string): Target hostname.
  * `"url.full"` (string): Complete target URL.
  * `"is_up"` (boolean): Binary availability state.
  * `"error.type"` (string | nil): Network or HTTP error reason if down.
  * `"ravner.domain_id"` (integer | nil): Associated domain ID.
  * `"ravner.domain_check_id"` (integer | nil): Associated check ID.
  """
  @spec emit_uptime_status(map(), map()) :: :ok
  def emit_uptime_status(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    record_and_broadcast([:ravner, :synthetic, :uptime, :status], :uptime, measurements, metadata)
  end

  @doc """
  Emits an incident state transition event `[:ravner, :synthetic, :incident, event_suffix]`.

  ## Parameters
  * `event_suffix` (atom): e.g. `:opened`, `:escalated`, `:resolved`.
  * `measurements`: e.g. `%{duration_seconds: 120}` or `%{consecutive_failures: 3}`.
  * `metadata`: e.g. `%{"incident.id" => 12, "incident.state" => "resolved"}`.
  """
  @spec emit_incident(atom(), map(), map()) :: :ok
  def emit_incident(event_suffix, measurements, metadata)
      when is_atom(event_suffix) and is_map(measurements) and is_map(metadata) do
    record_and_broadcast(
      [:ravner, :synthetic, :incident, event_suffix],
      :incident,
      measurements,
      metadata
    )
  end

  @doc """
  Emits a Google Lighthouse Core Web Vitals and PageSpeed scan event `[:ravner, :synthetic, :web_vitals, :stop]`.

  ## Measurements
  * `lcp_ms` (integer): Largest Contentful Paint in milliseconds.
  * `cls` (float): Cumulative Layout Shift.
  * `tbt_ms` (integer): Total Blocking Time in milliseconds.
  * `fcp_ms` (integer): First Contentful Paint in milliseconds.
  * `speed_index_ms` (integer): Speed Index.
  * `performance_score` (integer): Lighthouse performance score (0-100).
  * `accessibility_score` (integer): Lighthouse accessibility score (0-100).
  * `best_practices_score` (integer): Lighthouse best practices score (0-100).
  * `seo_score` (integer): Lighthouse SEO score (0-100).
  """
  @spec emit_web_vitals(map(), map()) :: :ok
  def emit_web_vitals(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    record_and_broadcast(
      [:ravner, :synthetic, :web_vitals, :stop],
      :web_vitals,
      measurements,
      metadata
    )
  end

  @doc """
  Emits an Accessibility (A11y / WCAG 2.1 AA) scan event `[:ravner, :synthetic, :a11y, :stop]`.

  ## Measurements
  * `violations_count` (integer): Total WCAG violations detected.
  * `warnings_count` (integer): Warning count.
  * `total_issues` (integer): Sum of violations and warnings.

  ## Metadata (OTel SemConv)
  * `"server.address"` (string): Hostname.
  * `"url.full"` (string): Target URL.
  * `"compliance.standard"` (string): e.g. `"WCAG2AA"`.
  * `"ravner.domain_id"` (integer | nil): Associated domain ID.
  """
  @spec emit_a11y(map(), map()) :: :ok
  def emit_a11y(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    record_and_broadcast([:ravner, :synthetic, :a11y, :stop], :a11y, measurements, metadata)
  end

  @doc """
  Emits a DNS zone & deliverability audit event `[:ravner, :synthetic, :dns, :stop]`.

  ## Measurements
  * `duration_ms` (integer): Lookup duration in milliseconds.
  * `record_count` (integer): Number of resolved DNS records.
  * `spf_valid` (integer): `1` if SPF TXT record present, else `0`.
  * `has_mx` (integer): `1` if MX records present, else `0`.

  ## Metadata (OTel SemConv)
  * `"server.address"` (string): Domain name.
  * `"ravner.domain_id"` (integer | nil): Associated domain ID.
  """
  @spec emit_dns_audit(map(), map()) :: :ok
  def emit_dns_audit(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    record_and_broadcast([:ravner, :synthetic, :dns, :stop], :dns, measurements, metadata)
  end

  @doc """
  Emits an HTTP security headers posture event `[:ravner, :synthetic, :security_headers, :stop]`.

  ## Measurements
  * `findings_count` (integer): Number of security posture findings.
  * `hsts_present` (integer): `1` if HSTS header present, else `0`.
  * `csp_present` (integer): `1` if CSP header present, else `0`.
  * `x_frame_present` (integer): `1` if X-Frame-Options present, else `0`.

  ## Metadata (OTel SemConv)
  * `"server.address"` (string): Hostname.
  * `"url.full"` (string): Probed URL.
  * `"security.deprecated_tls_detected"` (boolean): Whether TLS 1.0/1.1 is accepted.
  """
  @spec emit_security_headers(map(), map()) :: :ok
  def emit_security_headers(measurements, metadata)
      when is_map(measurements) and is_map(metadata) do
    record_and_broadcast(
      [:ravner, :synthetic, :security_headers, :stop],
      :security_headers,
      measurements,
      metadata
    )
  end

  @doc """
  Emits a synthetic test event of the given type
  (`:http`, `:uptime`, `:incident`, `:web_vitals`, `:a11y`, `:dns`, `:security_headers`, `:sca`, `:tls`, `:probe`)
  to verify the live telemetry and observability pipeline.
  """
  @spec emit_test_event(atom()) :: {:ok, map()}
  def emit_test_event(type \\ :http) do
    uid = System.unique_integer([:positive])

    case type do
      :http ->
        latency = Enum.random(25..450)
        status = Enum.random([200, 200, 200, 301, 404, 500])
        err = if status >= 400, do: "http_#{status}", else: nil

        measurements = %{duration_ms: latency, response_time_ms: if(err, do: nil, else: latency)}

        metadata = %{
          "server.address" => "test-service-#{rem(uid, 5) + 1}.ravner.internal",
          "url.full" => "https://test-service-#{rem(uid, 5) + 1}.ravner.internal/health",
          "http.request.method" => "HEAD",
          "http.response.status_code" => status,
          "error.type" => err,
          "test_event" => true
        }

        emit_http_probe(measurements, metadata)
        {:ok, %{type: :http, measurements: measurements, metadata: metadata}}

      :uptime ->
        latency = Enum.random(30..300)
        is_up = Enum.random([true, true, true, true, false])
        err = if is_up, do: nil, else: "econnrefused"

        measurements = %{
          status: if(is_up, do: 1, else: 0),
          response_time_ms: if(is_up, do: latency, else: 0)
        }

        metadata = %{
          "server.address" => "gateway-#{rem(uid, 4) + 1}.ravner.internal",
          "url.full" => "https://gateway-#{rem(uid, 4) + 1}.ravner.internal",
          "is_up" => is_up,
          "error.type" => err,
          "test_event" => true
        }

        emit_uptime_status(measurements, metadata)
        {:ok, %{type: :uptime, measurements: measurements, metadata: metadata}}

      :incident ->
        resolved? = Enum.random([true, false])
        suffix = if resolved?, do: :resolved, else: :opened
        duration = if resolved?, do: Enum.random(45..900), else: 0

        measurements =
          if resolved? do
            %{duration_seconds: duration}
          else
            %{consecutive_failures: Enum.random(2..5)}
          end

        metadata = %{
          "server.address" => "checkout-api-#{rem(uid, 3) + 1}.internal",
          "incident.id" => rem(uid, 1000) + 10,
          "incident.state" => to_string(suffix),
          "incident.threshold_used" => 2,
          "test_event" => true
        }

        emit_incident(suffix, measurements, metadata)
        {:ok, %{type: :incident, measurements: measurements, metadata: metadata}}

      :web_vitals ->
        perf = Enum.random(68..99)
        lcp = Enum.random(1100..3200)
        cls = Float.round(Enum.random(1..15) / 100.0, 3)
        tbt = Enum.random(20..350)

        measurements = %{
          lcp_ms: lcp,
          cls: cls,
          tbt_ms: tbt,
          fcp_ms: Enum.random(600..1500),
          speed_index_ms: Enum.random(1200..2800),
          performance_score: perf,
          accessibility_score: Enum.random(85..100),
          best_practices_score: Enum.random(90..100),
          seo_score: Enum.random(88..100)
        }

        metadata = %{
          "server.address" => "store-#{rem(uid, 4) + 1}.ravner.internal",
          "url.full" => "https://store-#{rem(uid, 4) + 1}.ravner.internal/",
          "test_event" => true
        }

        emit_web_vitals(measurements, metadata)
        {:ok, %{type: :web_vitals, measurements: measurements, metadata: metadata}}

      :a11y ->
        violations = Enum.random([0, 1, 3, 5])
        warnings = Enum.random([1, 4, 8])

        measurements = %{
          violations_count: violations,
          warnings_count: warnings,
          total_issues: violations + warnings
        }

        metadata = %{
          "server.address" => "portal-#{rem(uid, 3) + 1}.ravner.internal",
          "url.full" => "https://portal-#{rem(uid, 3) + 1}.ravner.internal/login",
          "compliance.standard" => "WCAG2AA",
          "test_event" => true
        }

        emit_a11y(measurements, metadata)
        {:ok, %{type: :a11y, measurements: measurements, metadata: metadata}}

      :dns ->
        duration = Enum.random(12..95)
        records = Enum.random(4..18)
        spf = Enum.random([1, 1, 1, 0])

        measurements = %{
          duration_ms: duration,
          record_count: records,
          spf_valid: spf,
          has_mx: 1
        }

        metadata = %{
          "server.address" => "domain-#{rem(uid, 6) + 1}.org",
          "test_event" => true
        }

        emit_dns_audit(measurements, metadata)
        {:ok, %{type: :dns, measurements: measurements, metadata: metadata}}

      :security_headers ->
        findings = Enum.random([0, 1, 2])
        hsts = Enum.random([1, 1, 0])
        csp = Enum.random([1, 0])

        measurements = %{
          findings_count: findings,
          hsts_present: hsts,
          csp_present: csp,
          x_frame_present: 1
        }

        metadata = %{
          "server.address" => "secure-edge-#{rem(uid, 4) + 1}.org",
          "url.full" => "https://secure-edge-#{rem(uid, 4) + 1}.org",
          "security.deprecated_tls_detected" => false,
          "test_event" => true
        }

        emit_security_headers(measurements, metadata)
        {:ok, %{type: :security_headers, measurements: measurements, metadata: metadata}}

      :sca ->
        latency = Enum.random(150..1200)
        vulns = Enum.random([0, 0, 1, 2, 4])
        critical = if vulns > 2, do: 1, else: 0
        high = if vulns > 0, do: vulns - critical, else: 0

        measurements = %{
          duration_ms: latency,
          vulnerability_count: vulns,
          critical_count: critical,
          high_count: high
        }

        metadata = %{
          "vcs.provider" => Enum.random(["bitbucket", "github", "gitlab"]),
          "vcs.repository.name" => "auth-service-#{uid}",
          "vcs.repository.url" => "https://bitbucket.org/acme/auth-service-#{uid}",
          "test_event" => true
        }

        emit_sca_scan(measurements, metadata)
        {:ok, %{type: :sca, measurements: measurements, metadata: metadata}}

      :tls ->
        days = Enum.random([12, 45, 90, 180, 365])
        handshake = Enum.random(15..80)

        measurements = %{days_until_expiry: days, handshake_ms: handshake}

        metadata = %{
          "server.address" => "secure-gateway-#{rem(uid, 4) + 1}.example.org",
          "tls.protocol.version" => Enum.random(["TLSv1.3", "TLSv1.3", "TLSv1.2"]),
          "tls.cipher" => "TLS_AES_256_GCM_SHA384",
          "tls.status" => if(days < 14, do: "expiring_soon", else: "valid"),
          "test_event" => true
        }

        emit_tls_probe(measurements, metadata)
        {:ok, %{type: :tls, measurements: measurements, metadata: metadata}}

      _ ->
        measurements = %{duration_ms: Enum.random(100..500), matches_count: 0}

        metadata = %{
          "server.address" => "portal-#{rem(uid, 3) + 1}.example.org",
          "probe.category" => "exposed_panel",
          "probe.name" => "actuator_env_check",
          "test_event" => true
        }

        emit_native_probe(measurements, metadata)
        {:ok, %{type: :probe, measurements: measurements, metadata: metadata}}
    end
  end

  # ── Internal Helpers ───────────────────────────────────────────────────────

  defp record_and_broadcast(event_name, type, measurements, metadata) do
    # 1. Standard BEAM :telemetry execution
    :telemetry.execute(event_name, measurements, metadata)

    # 2. Prepare standardized payload
    payload = %{
      id: System.unique_integer([:positive]),
      event: event_name,
      type: type,
      measurements: measurements,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    # 3. Buffer in memory for immediate catch-up on connect
    try do
      EventBuffer.push(payload)
    catch
      _, _ -> :ok
    end

    # 4. Broadcast live to Phoenix PubSub for real-time inspector UI
    try do
      Phoenix.PubSub.broadcast(Ravner.PubSub, @pubsub_topic, {:telemetry_event, payload})
    catch
      _, _ -> :ok
    end

    :ok
  end
end
