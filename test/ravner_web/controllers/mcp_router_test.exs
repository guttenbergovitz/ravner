defmodule RavnerWeb.McpRouterTest do
  use RavnerWeb.ConnCase, async: false

  import Ecto.Query
  import Ravner.AccountsFixtures
  import Ravner.DomainsFixtures

  alias Ravner.Accounts
  alias Ravner.Domains.Domain
  alias Ravner.Repo

  @test_token "test-mcp-secret-token"

  setup do
    original_token = Application.get_env(:ravner, :mcp_api_key)
    Application.put_env(:ravner, :mcp_api_key, @test_token)

    on_exit(fn ->
      if original_token do
        Application.put_env(:ravner, :mcp_api_key, original_token)
      else
        Application.delete_env(:ravner, :mcp_api_key)
      end
    end)

    :ok
  end

  # ── Authentication ─────────────────────────────────────────────────────────

  describe "POST /mcp authentication" do
    test "returns 401 with JSON-RPC error when token is missing", %{conn: conn} do
      payload = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/mcp", Jason.encode!(payload))

      assert response(conn, 401)
      decoded = Jason.decode!(response(conn, 401))

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["error"]["code"] == -32_600
      assert decoded["error"]["message"] =~ "Missing MCP authentication token"
    end

    test "returns 401 with JSON-RPC error when invalid Bearer token is provided", %{conn: conn} do
      payload = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer invalid-secret")
        |> post(~p"/mcp", Jason.encode!(payload))

      assert response(conn, 401)
      decoded = Jason.decode!(response(conn, 401))

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["error"]["code"] == -32_600
      assert decoded["error"]["message"] =~ "Invalid MCP authentication token"
    end

    test "accepts valid Bearer token matching system mcp_api_key", %{conn: conn} do
      payload = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{@test_token}")
        |> post(~p"/mcp", Jason.encode!(payload))

      assert response(conn, 200)
      decoded = Jason.decode!(response(conn, 200))

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert is_list(decoded["result"]["tools"])
    end

    test "accepts valid X-API-Key header matching system mcp_api_key", %{conn: conn} do
      payload = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", @test_token)
        |> post(~p"/mcp", Jason.encode!(payload))

      assert response(conn, 200)
      decoded = Jason.decode!(response(conn, 200))
      assert is_list(decoded["result"]["tools"])
    end

    test "accepts valid user session token and assigns user as actor", %{conn: conn} do
      user = user_fixture(%{role: :admin})
      session_token = Accounts.generate_user_session_token(user)

      payload = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{session_token}")
        |> post(~p"/mcp", Jason.encode!(payload))

      assert response(conn, 200)
      decoded = Jason.decode!(response(conn, 200))
      tools = decoded["result"]["tools"]
      tool_names = Enum.map(tools, & &1["name"])

      # Admin user sees policy-restricted governance tools
      assert "set_domain_lifecycle" in tool_names
      assert "list_users" in tool_names
    end
  end

  # ── MCP Protocol Lifecycle ──────────────────────────────────────────────────

  describe "POST /mcp protocol methods" do
    test "initialize handshake negotiates protocol and returns server info", %{conn: conn} do
      init_payload = %{
        "jsonrpc" => "2.0",
        "id" => 10,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{
            "name" => "test-suite-client",
            "version" => "1.0.0"
          }
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{@test_token}")
        |> post(~p"/mcp", Jason.encode!(init_payload))

      assert response(conn, 200)
      decoded = Jason.decode!(response(conn, 200))

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 10
      assert decoded["result"]["protocolVersion"] == "2025-06-18"
      assert decoded["result"]["serverInfo"]["name"] == "MCP Server"
      assert decoded["result"]["capabilities"]["tools"]["listChanged"] == false
    end

    test "tools/list returns exposed governance tools and respects Stop Line rule", %{conn: conn} do
      payload = %{
        "jsonrpc" => "2.0",
        "id" => 11,
        "method" => "tools/list"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{@test_token}")
        |> post(~p"/mcp", Jason.encode!(payload))

      assert response(conn, 200)
      decoded = Jason.decode!(response(conn, 200))
      tools = decoded["result"]["tools"]
      tool_names = Enum.map(tools, & &1["name"])

      # 1. Domains governance tools
      assert "list_domains" in tool_names
      assert "get_domain" in tool_names
      assert "get_domain_by_name" in tool_names
      assert "set_domain_lifecycle" in tool_names
      assert "assign_domain_project" in tool_names
      assert "assign_domain_contacts" in tool_names
      assert "list_domain_dns_records" in tool_names
      assert "list_domain_tech_evidence" in tool_names

      # 2. Inventory governance tools
      assert "list_projects" in tool_names
      assert "get_project" in tool_names
      assert "get_project_by_slug" in tool_names
      assert "list_organizations" in tool_names
      assert "get_organization" in tool_names
      assert "list_brands" in tool_names
      assert "get_brand" in tool_names
      assert "list_people" in tool_names
      assert "get_person" in tool_names
      assert "list_project_repositories" in tool_names

      # 3. Accounts governance tools
      assert "list_users" in tool_names
      assert "get_user" in tool_names

      # 4. Hybrid Architecture Stop Line Rule: verify high-volume runtime paths are NOT exposed
      refute "run_dns_scan" in tool_names
      refute "run_tech_scan" in tool_names
      refute "crawl_urls" in tool_names
      refute "oban_worker" in tool_names
    end
  end

  # ── Tool Execution & Governance Audit ───────────────────────────────────────

  describe "POST /mcp tool execution" do
    test "tools/call list_domains executes and returns filtered domain results", %{conn: conn} do
      domain =
        domain_fixture(%{name: "governance-test-#{System.unique_integer([:positive])}.com"})

      payload = %{
        "jsonrpc" => "2.0",
        "id" => 20,
        "method" => "tools/call",
        "params" => %{
          "name" => "list_domains",
          "arguments" => %{"limit" => 10}
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{@test_token}")
        |> post(~p"/mcp", Jason.encode!(payload))

      assert response(conn, 200)
      decoded = Jason.decode!(response(conn, 200))

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 20
      assert decoded["result"]["isError"] == false

      content_text = hd(decoded["result"]["content"])["text"]
      records = Jason.decode!(content_text)
      assert is_list(records)

      domain_names = Enum.map(records, & &1["name"])
      assert domain.name in domain_names
    end

    test "tools/call get_domain returns domain by ID", %{conn: conn} do
      domain = domain_fixture(%{name: "lookup-test-#{System.unique_integer([:positive])}.com"})

      payload = %{
        "jsonrpc" => "2.0",
        "id" => 21,
        "method" => "tools/call",
        "params" => %{
          "name" => "get_domain",
          "arguments" => %{"id" => domain.id}
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{@test_token}")
        |> post(~p"/mcp", Jason.encode!(payload))

      assert response(conn, 200)
      decoded = Jason.decode!(response(conn, 200))

      assert decoded["result"]["isError"] == false
      item = Jason.decode!(hd(decoded["result"]["content"])["text"])
      assert item["id"] == domain.id
      assert item["name"] == domain.name
    end

    test "tools/call set_domain_lifecycle executes mutation and creates AshPaperTrail audit version",
         %{conn: conn} do
      domain =
        domain_fixture(%{
          name: "audit-test-#{System.unique_integer([:positive])}.com",
          lifecycle_state: :active
        })

      payload = %{
        "jsonrpc" => "2.0",
        "id" => 22,
        "method" => "tools/call",
        "params" => %{
          "name" => "set_domain_lifecycle",
          "arguments" => %{
            "id" => domain.id,
            "input" => %{"lifecycle_state" => "deprecated"}
          }
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{@test_token}")
        |> post(~p"/mcp", Jason.encode!(payload))

      assert response(conn, 200)
      decoded = Jason.decode!(response(conn, 200))

      assert decoded["result"]["isError"] == false
      res_item = Jason.decode!(hd(decoded["result"]["content"])["text"])
      assert res_item["id"] == domain.id
      assert res_item["lifecycle_state"] == "deprecated"

      # Verify database state was updated
      updated_domain = Repo.get!(Domain, domain.id)
      assert updated_domain.lifecycle_state == :deprecated

      # Verify AshPaperTrail audit version was created
      version =
        Repo.one(
          from(v in "domains_versions",
            where: v.version_source_id == ^domain.id,
            order_by: [desc: v.version_inserted_at],
            limit: 1,
            select: %{
              action_name: v.version_action_name,
              changes: v.changes
            }
          )
        )

      assert version != nil
      assert version.action_name == "set_lifecycle"
      assert version.changes["lifecycle_state"] == "deprecated"
    end

    test "enforces Ash policy: viewer role is forbidden from set_domain_lifecycle mutation", %{
      conn: conn
    } do
      viewer_user = user_fixture(%{role: :viewer})
      session_token = Accounts.generate_user_session_token(viewer_user)

      domain =
        domain_fixture(%{
          name: "policy-test-#{System.unique_integer([:positive])}.com",
          lifecycle_state: :active
        })

      payload = %{
        "jsonrpc" => "2.0",
        "id" => 23,
        "method" => "tools/call",
        "params" => %{
          "name" => "set_domain_lifecycle",
          "arguments" => %{
            "id" => domain.id,
            "input" => %{"lifecycle_state" => "abandoned"}
          }
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{session_token}")
        |> post(~p"/mcp", Jason.encode!(payload))

      assert response(conn, 200)
      decoded = Jason.decode!(response(conn, 200))

      # AshAi policy check ensures tool is either filtered out (-32602 Tool not found)
      # or returns a tool execution error (isError: true), never executing unauthorized mutation.
      assert match?(%{"error" => %{"code" => -32_602}}, decoded) or
               decoded["result"]["isError"] == true

      # Verify database was NOT changed
      unchanged_domain = Repo.get!(Domain, domain.id)
      assert unchanged_domain.lifecycle_state == :active
    end
  end
end
