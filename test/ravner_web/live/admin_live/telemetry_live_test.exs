defmodule RavnerWeb.AdminLive.TelemetryLiveTest do
  use RavnerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.Telemetry.EventBuffer
  alias Ravner.Telemetry.Synthetic

  setup %{conn: conn} do
    EventBuffer.clear()
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  describe "admin telemetry & otel inspector live view" do
    test "mounts and renders empty state and metric cards", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/telemetry")

      assert html =~ "Telemetry &amp; OTel Inspector"
      assert html =~ "LIVE STREAM"
      assert has_element?(view, "#stat-total-events")
      assert has_element?(view, "#stat-http-events")
      assert has_element?(view, "#stat-sca-events")
      assert has_element?(view, "#stat-avg-latency")
      assert has_element?(view, "#stat-vulnerabilities")
      assert has_element?(view, "#stat-error-events")
      assert html =~ "No telemetry events captured yet"
    end

    test "emits test events for HTTP, Uptime, Web Vitals, and SCA and updates live stream", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/telemetry")

      # Click Test HTTP button
      view
      |> element("#btn-emit-test-http")
      |> render_click()

      assert render(view) =~ "HTTP"
      assert render(view) =~ "ravner.internal"

      # Click Test Uptime button
      view
      |> element("#btn-emit-test-uptime")
      |> render_click()

      assert render(view) =~ "UPTIME"

      # Click Test Vitals button
      view
      |> element("#btn-emit-test-vitals")
      |> render_click()

      assert render(view) =~ "WEB VITALS"
      assert render(view) =~ "LCP:"

      # Click Test SCA button
      view
      |> element("#btn-emit-test-sca")
      |> render_click()

      assert render(view) =~ "SCA REPO"
      assert render(view) =~ "auth-service"
    end

    test "toggles stream pause and clear buffer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/telemetry")

      # Toggle pause
      view
      |> element("#btn-toggle-pause")
      |> render_click()

      assert render(view) =~ "STREAM PAUSED"
      assert render(view) =~ "Resume Stream"

      # Resume
      view
      |> element("#btn-toggle-pause")
      |> render_click()

      assert render(view) =~ "LIVE STREAM"

      # Clear events
      view
      |> element("#btn-clear-events")
      |> render_click()

      assert render(view) =~ "Telemetry buffer cleared"
    end

    test "toggles OpenTelemetry JSON detail drawer", %{conn: conn} do
      {:ok, _event} = Synthetic.emit_test_event(:http)

      {:ok, view, _html} = live(conn, ~p"/admin/telemetry")

      refute has_element?(view, "#otel-json-drawer")

      # Click OTel JSON toggle
      view
      |> element("button[phx-click='toggle_details']")
      |> render_click()

      assert has_element?(view, "#otel-json-drawer")
      assert render(view) =~ "OpenTelemetry Event Payload (SemConv)"
      assert render(view) =~ "server.address"
    end

    test "filters events by type", %{conn: conn} do
      {:ok, _} = Synthetic.emit_test_event(:http)
      {:ok, _} = Synthetic.emit_test_event(:sca)

      {:ok, view, _html} = live(conn, ~p"/admin/telemetry")

      assert has_element?(view, "#telemetry-events-stream", "HTTP")
      assert has_element?(view, "#telemetry-events-stream", "SCA REPO")

      # Filter only SCA
      view
      |> element("#filter-type-sca")
      |> render_click()

      assert has_element?(view, "#telemetry-events-stream", "SCA REPO")
      refute has_element?(view, "#telemetry-events-stream", "HTTP")
    end

    test "denies access to non-admin/editor users", %{conn: conn} do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})
      authed_conn = log_in_user(conn, viewer)

      assert {:error, {:redirect, %{to: "/domains"}}} = live(authed_conn, ~p"/admin/telemetry")
    end
  end
end
