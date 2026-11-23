defmodule RavnerWeb.MetricsControllerTest do
  use RavnerWeb.ConnCase, async: false

  alias Ravner.Telemetry.EventBuffer
  alias Ravner.Telemetry.Synthetic

  setup do
    EventBuffer.clear()
    original_token = Application.get_env(:ravner, :metrics_bearer_token)

    on_exit(fn ->
      if original_token do
        Application.put_env(:ravner, :metrics_bearer_token, original_token)
      else
        Application.delete_env(:ravner, :metrics_bearer_token)
      end
    end)

    :ok
  end

  describe "GET /metrics unauthenticated behavior" do
    test "renders Prometheus format metrics when no token is configured in test env", %{
      conn: conn
    } do
      Application.delete_env(:ravner, :metrics_bearer_token)

      conn = get(conn, ~p"/metrics")
      assert response(conn, 200) =~ "# HELP ravner_synthetic_events_total"
      assert response_content_type(conn, :plain) =~ "text/plain"

      body = response(conn, 200)
      assert body =~ "# TYPE ravner_synthetic_events_total counter"
      assert body =~ "ravner_synthetic_probes_by_type_total{type=\"http\"}"
      assert body =~ "vm_memory_bytes{kind=\"total\"}"
      assert body =~ "vm_process_count"
    end
  end

  describe "GET /metrics security with token configured" do
    @test_token "super-secret-prometheus-token-12345"

    setup do
      Application.put_env(:ravner, :metrics_bearer_token, @test_token)
      :ok
    end

    test "returns 401 Unauthorized when Authorization header is missing", %{conn: conn} do
      conn = get(conn, ~p"/metrics")

      assert response(conn, 401) =~ "401 Unauthorized"
      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="Ravner Metrics")]
    end

    test "returns 401 Unauthorized when invalid Bearer token is provided", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid-token-xyz")
        |> get(~p"/metrics")

      assert response(conn, 401) =~ "401 Unauthorized"
    end

    test "returns 200 OK when valid Bearer token is provided", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@test_token}")
        |> get(~p"/metrics")

      assert response(conn, 200) =~ "# HELP ravner_synthetic_events_total"
    end

    test "returns 200 OK when valid Basic Auth is provided", %{conn: conn} do
      encoded = Base.encode64("prometheus:#{@test_token}")

      conn =
        conn
        |> put_req_header("authorization", "Basic #{encoded}")
        |> get(~p"/metrics")

      assert response(conn, 200) =~ "# HELP ravner_synthetic_events_total"
    end

    test "returns 200 OK when token is passed as query parameter", %{conn: conn} do
      conn = get(conn, ~p"/metrics?token=#{@test_token}")
      assert response(conn, 200) =~ "# HELP ravner_synthetic_events_total"
    end
  end

  describe "GET /metrics payload content with synthetic events" do
    test "includes latest synthetic probes and host statuses in Prometheus output", %{conn: conn} do
      Application.delete_env(:ravner, :metrics_bearer_token)

      Synthetic.emit_http_probe(
        %{duration_ms: 135, response_time_ms: 130},
        %{
          "server.address" => "payments.example.com",
          "url.full" => "https://payments.example.com/health",
          "http.response.status_code" => 200
        }
      )

      Synthetic.emit_web_vitals(
        %{
          lcp_ms: 1600,
          cls: 0.05,
          performance_score: 95
        },
        %{
          "server.address" => "store.example.com",
          "url.full" => "https://store.example.com/"
        }
      )

      conn = get(conn, ~p"/metrics")
      body = response(conn, 200)

      assert body =~ ~s(ravner_domain_status{server_address="payments.example.com"} 1)
      assert body =~ ~s(ravner_domain_latency_ms{server_address="payments.example.com"} 135)
      assert body =~ ~s(ravner_synthetic_probes_by_type_total{type="http"} 1)
      assert body =~ ~s(ravner_synthetic_probes_by_type_total{type="web_vitals"} 1)
    end
  end

  describe "GET /metrics persisted domain, lighthouse, a11y, and repository security metrics" do
    test "exports SSL, risk, latest Lighthouse, latest A11y, and repository CVE gauges", %{
      conn: conn
    } do
      Application.delete_env(:ravner, :metrics_bearer_token)

      alias Ravner.A11y.A11yScan
      alias Ravner.Domains
      alias Ravner.DomainsFixtures
      alias Ravner.Inventory.{Organization, Project, ProjectRepository}
      alias Ravner.Lighthouse.LighthouseScan
      alias Ravner.Repo

      domain = DomainsFixtures.domain_fixture(%{name: "acme-metrics.example.com"})

      {:ok, _metadata} =
        Domains.upsert_domain_metadata(domain.id, %{
          is_up: true,
          ssl_days_remaining: 42,
          risk_score: 88,
          risk_grade: "B"
        })

      older_ts = ~U[2026-11-01 10:00:00Z]
      newer_ts = ~U[2026-11-10 10:00:00Z]

      # Older completed Lighthouse scan (should be superseded by newer_ts)
      Repo.insert!(%LighthouseScan{
        domain_id: domain.id,
        url: "https://acme-metrics.example.com",
        status: "completed",
        performance_score: 50,
        lcp_ms: 4200,
        completed_at: older_ts
      })

      # Newer completed Lighthouse scan
      Repo.insert!(%LighthouseScan{
        domain_id: domain.id,
        url: "https://acme-metrics.example.com",
        status: "completed",
        performance_score: 91,
        accessibility_score: 96,
        best_practices_score: 100,
        seo_score: 92,
        fcp_ms: 950,
        lcp_ms: 1850,
        tbt_ms: 120,
        speed_index_ms: 2100,
        cls: 0.04,
        completed_at: newer_ts
      })

      # Pending Lighthouse scan should be ignored
      Repo.insert!(%LighthouseScan{
        domain_id: domain.id,
        url: "https://acme-metrics.example.com",
        status: "pending",
        performance_score: 10
      })

      # Older vs newer completed A11y scans
      Repo.insert!(%A11yScan{
        domain_id: domain.id,
        url: "https://acme-metrics.example.com",
        standard: "WCAG2AA",
        status: "completed",
        violations_count: 15,
        warnings_count: 8,
        completed_at: older_ts
      })

      Repo.insert!(%A11yScan{
        domain_id: domain.id,
        url: "https://acme-metrics.example.com",
        standard: "WCAG2AA",
        status: "completed",
        violations_count: 3,
        warnings_count: 7,
        completed_at: newer_ts
      })

      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "Acme Org", slug: "acme-org-metrics"})
        |> Ash.create!(authorize?: false)

      project =
        Project
        |> Ash.Changeset.for_create(:create, %{
          name: "Acme Web",
          slug: "acme-web-metrics",
          organization_id: org.id
        })
        |> Ash.create!(authorize?: false)

      ProjectRepository
      |> Ash.Changeset.for_create(:create, %{
        url: "https://bitbucket.org/acme/acme-frontend",
        external_id: "acme/acme-frontend",
        project_id: project.id,
        domain_id: domain.id,
        critical_vuln_count: 2,
        high_vuln_count: 5,
        medium_vuln_count: 9,
        low_vuln_count: 4,
        secrets_count: 1
      })
      |> Ash.create!(authorize?: false)

      conn = get(conn, ~p"/metrics")
      body = response(conn, 200)

      # Domain governance & SSL
      assert body =~ ~s(ravner_domain_up{domain="acme-metrics.example.com"} 1)
      assert body =~ ~s(ravner_domain_ssl_days_remaining{domain="acme-metrics.example.com"} 42)

      assert body =~
               ~s(ravner_domain_risk_score{domain="acme-metrics.example.com",grade="B"} 88)

      # Latest Lighthouse only
      assert body =~
               ~s(ravner_lighthouse_score{domain="acme-metrics.example.com",category="performance"} 91)

      assert body =~
               ~s(ravner_lighthouse_score{domain="acme-metrics.example.com",category="accessibility"} 96)

      assert body =~
               ~s(ravner_lighthouse_score{domain="acme-metrics.example.com",category="best_practices"} 100)

      assert body =~
               ~s(ravner_lighthouse_score{domain="acme-metrics.example.com",category="seo"} 92)

      assert body =~
               ~s(ravner_lighthouse_web_vital_ms{domain="acme-metrics.example.com",metric="lcp"} 1850)

      assert body =~ ~s(ravner_lighthouse_cls{domain="acme-metrics.example.com"} 0.04)

      refute body =~
               ~s(ravner_lighthouse_score{domain="acme-metrics.example.com",category="performance"} 50)

      refute body =~
               ~s(ravner_lighthouse_score{domain="acme-metrics.example.com",category="performance"} 10)

      # Latest A11y only
      assert body =~
               ~s(ravner_a11y_violations{domain="acme-metrics.example.com",standard="WCAG2AA"} 3)

      assert body =~
               ~s(ravner_a11y_warnings{domain="acme-metrics.example.com",standard="WCAG2AA"} 7)

      refute body =~
               ~s(ravner_a11y_violations{domain="acme-metrics.example.com",standard="WCAG2AA"} 15)

      # Repository CVEs & secrets
      assert body =~
               ~s(ravner_repository_vulnerabilities{project="Acme Web",repository="acme/acme-frontend",domain="acme-metrics.example.com",severity="critical"} 2)

      assert body =~
               ~s(ravner_repository_vulnerabilities{project="Acme Web",repository="acme/acme-frontend",domain="acme-metrics.example.com",severity="high"} 5)

      assert body =~
               ~s(ravner_repository_vulnerabilities{project="Acme Web",repository="acme/acme-frontend",domain="acme-metrics.example.com",severity="medium"} 9)

      assert body =~
               ~s(ravner_repository_vulnerabilities{project="Acme Web",repository="acme/acme-frontend",domain="acme-metrics.example.com",severity="low"} 4)

      assert body =~
               ~s(ravner_repository_secrets{project="Acme Web",repository="acme/acme-frontend",domain="acme-metrics.example.com"} 1)
    end
  end
end
