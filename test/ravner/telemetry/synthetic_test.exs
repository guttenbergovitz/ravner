defmodule Ravner.Telemetry.SyntheticTest do
  use ExUnit.Case, async: false

  alias Ravner.Telemetry.EventBuffer
  alias Ravner.Telemetry.Synthetic

  setup do
    EventBuffer.clear()
    :ok
  end

  describe "synthetic telemetry emission" do
    test "emits [:ravner, :synthetic, :http, :stop] with OTel metadata" do
      ref = make_ref()
      parent = self()
      handler_id = "test-http-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:ravner, :synthetic, :http, :stop],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      measurements = %{duration_ms: 125, response_time_ms: 120}

      metadata = %{
        "server.address" => "api.example.com",
        "url.full" => "https://api.example.com/health",
        "http.request.method" => "HEAD",
        "http.response.status_code" => 200,
        "error.type" => nil
      }

      assert :ok = Synthetic.emit_http_probe(measurements, metadata)

      assert_receive {:telemetry_event, [:ravner, :synthetic, :http, :stop], received_m,
                      received_meta}

      assert received_m.duration_ms == 125
      assert received_m.response_time_ms == 120
      assert received_meta["server.address"] == "api.example.com"
      assert received_meta["http.response.status_code"] == 200

      # Also buffered in EventBuffer
      events = EventBuffer.list()
      assert length(events) == 1
      assert hd(events).type == :http
    end

    test "emits [:ravner, :synthetic, :sca, :stop] with vulnerability counts" do
      ref = make_ref()
      parent = self()
      handler_id = "test-sca-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:ravner, :synthetic, :sca, :stop],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      measurements = %{
        duration_ms: 450,
        vulnerability_count: 2,
        critical_count: 1,
        high_count: 1
      }

      metadata = %{
        "vcs.provider" => "bitbucket",
        "vcs.repository.name" => "billing-worker",
        "vcs.repository.url" => "https://bitbucket.org/acme/billing-worker"
      }

      assert :ok = Synthetic.emit_sca_scan(measurements, metadata)

      assert_receive {:telemetry_event, [:ravner, :synthetic, :sca, :stop], received_m,
                      received_meta}

      assert received_m.vulnerability_count == 2
      assert received_m.critical_count == 1
      assert received_meta["vcs.provider"] == "bitbucket"
    end

    test "emits [:ravner, :synthetic, :uptime, :status]" do
      ref = make_ref()
      parent = self()
      handler_id = "test-uptime-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:ravner, :synthetic, :uptime, :status],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok =
               Synthetic.emit_uptime_status(
                 %{status: 1, response_time_ms: 85},
                 %{
                   "server.address" => "app.example.com",
                   "url.full" => "https://app.example.com",
                   "is_up" => true
                 }
               )

      assert_receive {:telemetry_event, [:ravner, :synthetic, :uptime, :status], m, meta}
      assert m.status == 1
      assert m.response_time_ms == 85
      assert meta["is_up"] == true
    end

    test "emits [:ravner, :synthetic, :incident, :resolved]" do
      ref = make_ref()
      parent = self()
      handler_id = "test-incident-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:ravner, :synthetic, :incident, :resolved],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok =
               Synthetic.emit_incident(
                 :resolved,
                 %{duration_seconds: 340},
                 %{"incident.id" => 42, "incident.state" => "resolved"}
               )

      assert_receive {:telemetry_event, [:ravner, :synthetic, :incident, :resolved], m, meta}
      assert m.duration_seconds == 340
      assert meta["incident.id"] == 42
    end

    test "emits [:ravner, :synthetic, :web_vitals, :stop]" do
      ref = make_ref()
      parent = self()
      handler_id = "test-vitals-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:ravner, :synthetic, :web_vitals, :stop],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok =
               Synthetic.emit_web_vitals(
                 %{lcp_ms: 1850, cls: 0.04, performance_score: 92},
                 %{"server.address" => "example.com", "url.full" => "https://example.com"}
               )

      assert_receive {:telemetry_event, [:ravner, :synthetic, :web_vitals, :stop], m, meta}
      assert m.lcp_ms == 1850
      assert m.performance_score == 92
      assert meta["server.address"] == "example.com"
    end

    test "emits [:ravner, :synthetic, :a11y, :stop]" do
      ref = make_ref()
      parent = self()
      handler_id = "test-a11y-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:ravner, :synthetic, :a11y, :stop],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok =
               Synthetic.emit_a11y(
                 %{violations_count: 2, warnings_count: 5, total_issues: 7},
                 %{"server.address" => "example.com", "compliance.standard" => "WCAG2AA"}
               )

      assert_receive {:telemetry_event, [:ravner, :synthetic, :a11y, :stop], m, meta}
      assert m.violations_count == 2
      assert meta["compliance.standard"] == "WCAG2AA"
    end

    test "emits [:ravner, :synthetic, :dns, :stop]" do
      ref = make_ref()
      parent = self()
      handler_id = "test-dns-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:ravner, :synthetic, :dns, :stop],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok =
               Synthetic.emit_dns_audit(
                 %{duration_ms: 45, record_count: 12, spf_valid: 1, has_mx: 1},
                 %{"server.address" => "example.com"}
               )

      assert_receive {:telemetry_event, [:ravner, :synthetic, :dns, :stop], m, meta}
      assert m.record_count == 12
      assert m.spf_valid == 1
      assert meta["server.address"] == "example.com"
    end

    test "emits [:ravner, :synthetic, :security_headers, :stop]" do
      ref = make_ref()
      parent = self()
      handler_id = "test-sec-headers-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:ravner, :synthetic, :security_headers, :stop],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok =
               Synthetic.emit_security_headers(
                 %{findings_count: 1, hsts_present: 1, csp_present: 0, x_frame_present: 1},
                 %{"server.address" => "example.com", "url.full" => "https://example.com"}
               )

      assert_receive {:telemetry_event, [:ravner, :synthetic, :security_headers, :stop], m, meta}
      assert m.hsts_present == 1
      assert m.csp_present == 0
      assert meta["server.address"] == "example.com"
    end

    test "emit_test_event generates and buffers simulated events for all supported types" do
      types = [
        :http,
        :uptime,
        :incident,
        :web_vitals,
        :a11y,
        :dns,
        :security_headers,
        :sca,
        :tls,
        :probe
      ]

      for type <- types do
        {:ok, result} = Synthetic.emit_test_event(type)
        assert result.type == type
        assert result.metadata["test_event"] == true
      end

      events = EventBuffer.list()
      assert length(events) == length(types)
    end

    test "EventBuffer ring buffer and stats computation across all categories" do
      EventBuffer.clear()
      assert EventBuffer.list() == []
      assert EventBuffer.stats().total == 0

      Synthetic.emit_test_event(:http)
      Synthetic.emit_test_event(:uptime)
      Synthetic.emit_test_event(:incident)
      Synthetic.emit_test_event(:web_vitals)
      Synthetic.emit_test_event(:a11y)
      Synthetic.emit_test_event(:dns)
      Synthetic.emit_test_event(:security_headers)
      Synthetic.emit_test_event(:sca)

      stats = EventBuffer.stats()
      assert stats.total == 8
      assert stats.http_count == 1
      assert stats.uptime_count == 1
      assert stats.incident_count == 1
      assert stats.web_vitals_count == 1
      assert stats.a11y_count == 1
      assert stats.dns_count == 1
      assert stats.security_headers_count == 1
      assert stats.sca_count == 1
    end
  end
end
