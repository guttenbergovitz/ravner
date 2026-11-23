defmodule RavnerWeb.Api.JsonApiTest do
  use RavnerWeb.ConnCase, async: false

  alias Ravner.Inventory
  alias Ravner.Domains

  setup do
    admin = Ravner.AccountsFixtures.user_fixture(%{role: :admin})
    {:ok, admin: admin}
  end

  describe "OpenAPI and Swagger UI endpoints" do
    test "GET /api/v1/open_api returns valid OpenAPI 3.0 specification for admins", %{
      conn: conn,
      admin: admin
    } do
      conn =
        conn
        |> log_in_user(admin)
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/open_api")

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert body["openapi"] =~ "3.0"
      assert body["info"]["title"] == "Ravner Governance & Inventory REST API"
      assert body["info"]["version"] == Application.spec(:ravner, :vsn) |> to_string()

      paths = body["paths"]
      assert Map.has_key?(paths, "/api/v1/applications")
      assert Map.has_key?(paths, "/api/v1/applications/{id}")
      assert Map.has_key?(paths, "/api/v1/projects")
      assert Map.has_key?(paths, "/api/v1/organizations")
      assert Map.has_key?(paths, "/api/v1/brands")
      assert Map.has_key?(paths, "/api/v1/domains")
    end

    test "GET /api/v1/open_api redirects anonymous users", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/open_api")

      assert conn.status == 401
    end

    test "GET /api/v1/open_api rejects non-admin users", %{conn: conn} do
      viewer = Ravner.AccountsFixtures.user_fixture(%{role: :viewer})

      conn =
        conn
        |> log_in_user(viewer)
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/open_api")

      assert conn.status == 401
    end

    test "GET /api/swagger-ui loads Swagger UI interface for admins", %{
      conn: conn,
      admin: admin
    } do
      conn = conn |> log_in_user(admin) |> get("/api/swagger-ui")
      assert conn.status == 200
      assert response(conn, 200) =~ "swagger-ui"
    end

    test "GET /api/swagger-ui redirects anonymous users", %{conn: conn} do
      conn = get(conn, "/api/swagger-ui")
      assert redirected_to(conn) == "/users/log-in"
    end

    test "GET /api/swagger-ui redirects non-admin users", %{conn: conn} do
      viewer = Ravner.AccountsFixtures.user_fixture(%{role: :viewer})
      conn = conn |> log_in_user(viewer) |> get("/api/swagger-ui")
      assert redirected_to(conn) == "/domains"
    end
  end

  describe "JSON:API Resources - Applications (/api/v1/applications)" do
    test "GET /api/v1/applications returns list of applications", %{conn: conn, admin: admin} do
      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "API Corp",
            slug: "api-corp-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      {:ok, project} =
        Inventory.create_project(
          %{
            name: "API Project",
            slug: "api-project-#{System.unique_integer([:positive])}",
            organization_id: org.id
          },
          actor: admin
        )

      {:ok, app} =
        Inventory.create_application(
          %{
            name: "API Application",
            slug: "api-app-#{System.unique_integer([:positive])}",
            app_type: :api,
            project_id: project.id
          },
          actor: admin
        )

      conn =
        conn
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/applications")

      assert conn.status == 200
      response_data = json_response(conn, 200)
      assert is_list(response_data["data"])

      ids = Enum.map(response_data["data"], & &1["id"])
      assert to_string(app.id) in ids
    end

    test "GET /api/v1/applications/:id returns specific application", %{conn: conn, admin: admin} do
      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "API Corp 2",
            slug: "api-corp-2-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      {:ok, project} =
        Inventory.create_project(
          %{
            name: "API Project 2",
            slug: "api-project-2-#{System.unique_integer([:positive])}",
            organization_id: org.id
          },
          actor: admin
        )

      {:ok, app} =
        Inventory.create_application(
          %{
            name: "Storefront API",
            slug: "storefront-api-#{System.unique_integer([:positive])}",
            app_type: :storefront,
            lifecycle_state: :active,
            project_id: project.id
          },
          actor: admin
        )

      conn =
        conn
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/applications/#{app.id}")

      assert conn.status == 200
      data = json_response(conn, 200)["data"]
      assert data["id"] == to_string(app.id)
      assert data["type"] == "application"
      assert data["attributes"]["name"] == "Storefront API"
      assert data["attributes"]["app_type"] == "storefront"
    end
  end

  describe "JSON:API Resources - Domains (/api/v1/domains)" do
    test "GET /api/v1/domains returns list of domains", %{conn: conn, admin: admin} do
      {:ok, domain} =
        Domains.create_domain(
          %{
            name: "api-domain-#{System.unique_integer([:positive])}.example.com",
            type: :domain,
            url: "https://example.com"
          },
          actor: admin
        )

      conn =
        conn
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/domains")

      assert conn.status == 200
      response_data = json_response(conn, 200)
      assert is_list(response_data["data"])

      ids = Enum.map(response_data["data"], & &1["id"])
      assert to_string(domain.id) in ids
    end
  end

  describe "Authentication & Authorization (RequireApiAuth)" do
    test "authenticates with bearer user token and authorizes admin", %{conn: conn, admin: admin} do
      token = Ravner.Accounts.generate_user_session_token(admin)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/applications")

      assert conn.status == 200
    end

    test "authenticates with system api key when configured", %{conn: conn} do
      Application.put_env(:ravner, :api_key, "secret-test-key-1234")

      on_exit(fn ->
        Application.delete_env(:ravner, :api_key)
      end)

      # Valid key
      valid_conn =
        conn
        |> put_req_header("x-api-key", "secret-test-key-1234")
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/applications")

      assert valid_conn.status == 200

      # Missing key
      unauth_conn =
        conn
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/applications")

      assert unauth_conn.status == 401
      errors = json_response(unauth_conn, 401)["errors"]
      assert hd(errors)["detail"] =~ "Missing API authentication token"
    end

    test "authenticates with Enterprise ApiToken and enforces least privilege (:viewer)", %{
      conn: conn,
      admin: admin
    } do
      {:ok, _token_record, raw_secret} =
        Ravner.Accounts.create_api_token(
          %{
            name: "CI Scraper Token",
            role: :viewer
          },
          actor: admin
        )

      # 1. Read is permitted for :viewer
      read_conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_secret}")
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/applications")

      assert read_conn.status == 200

      # 2. Write (create) is forbidden for :viewer under Ash policy
      create_conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_secret}")
        |> put_req_header("accept", "application/vnd.api+json")
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/applications", %{
          "data" => %{
            "type" => "application",
            "attributes" => %{
              "name" => "Unauthorized App",
              "slug" => "unauthorized-app"
            }
          }
        })

      assert create_conn.status == 403
    end

    test "enforces acceptable source IP / CIDR allowlist", %{conn: conn, admin: admin} do
      {:ok, _token_record, raw_secret} =
        Ravner.Accounts.create_api_token(
          %{
            name: "Restricted IP Token",
            role: :admin,
            allowed_ips: ["10.0.0.0/8", "192.168.1.100"]
          },
          actor: admin
        )

      # Request with default conn remote_ip (usually {127, 0, 0, 1}) -> Rejected
      rejected_conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_secret}")
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/applications")

      assert rejected_conn.status == 403
      errors = json_response(rejected_conn, 403)["errors"]
      assert hd(errors)["detail"] =~ "not authorized for this API token"

      # Request with matching IP
      allowed_conn =
        conn
        |> Map.put(:remote_ip, {192, 168, 1, 100})
        |> put_req_header("authorization", "Bearer #{raw_secret}")
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/applications")

      assert allowed_conn.status == 200
    end

    test "enforces request URL and method scoping (allowed_paths)", %{conn: conn, admin: admin} do
      {:ok, _token_record, raw_secret} =
        Ravner.Accounts.create_api_token(
          %{
            name: "Domains Only Token",
            role: :admin,
            allowed_paths: ["GET /api/v1/domains*"]
          },
          actor: admin
        )

      # Allowed endpoint
      domains_conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_secret}")
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/domains")

      assert domains_conn.status == 200

      # Blocked endpoint
      apps_conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_secret}")
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/applications")

      assert apps_conn.status == 403
      errors = json_response(apps_conn, 403)["errors"]
      assert hd(errors)["detail"] =~ "is not permitted for this API token"
    end

    test "rejects revoked or expired Enterprise ApiTokens", %{conn: conn, admin: admin} do
      # Revoked
      {:ok, token_record, raw_secret} =
        Ravner.Accounts.create_api_token(
          %{
            name: "Revoked Token",
            role: :viewer
          },
          actor: admin
        )

      {:ok, _revoked} = Ravner.Accounts.revoke_api_token(token_record, actor: admin)

      revoked_conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_secret}")
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/applications")

      assert revoked_conn.status == 401
      errors = json_response(revoked_conn, 401)["errors"]
      assert hd(errors)["detail"] =~ "has been revoked"

      # Expired
      {:ok, _expired_token, expired_secret} =
        Ravner.Accounts.create_api_token(
          %{
            name: "Expired Token",
            role: :viewer,
            expires_at: DateTime.utc_now() |> DateTime.add(-3600, :second)
          },
          actor: admin
        )

      expired_conn =
        conn
        |> put_req_header("authorization", "Bearer #{expired_secret}")
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/applications")

      assert expired_conn.status == 401
      errors = json_response(expired_conn, 401)["errors"]
      assert hd(errors)["detail"] =~ "has expired"
    end
  end
end
