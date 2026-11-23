defmodule RavnerWeb.Plugs.RequireMcpAuthTest do
  use RavnerWeb.ConnCase, async: false

  import Ravner.AccountsFixtures

  alias Ravner.Accounts
  alias RavnerWeb.Plugs.RequireMcpAuth

  @test_token "unit-test-mcp-token"

  setup do
    original_token = Application.get_env(:ravner, :mcp_api_key)
    original_email = Application.get_env(:ravner, :mcp_actor_email)
    Application.put_env(:ravner, :mcp_api_key, @test_token)

    on_exit(fn ->
      if original_token do
        Application.put_env(:ravner, :mcp_api_key, original_token)
      else
        Application.delete_env(:ravner, :mcp_api_key)
      end

      if original_email do
        Application.put_env(:ravner, :mcp_actor_email, original_email)
      else
        Application.delete_env(:ravner, :mcp_actor_email)
      end
    end)

    :ok
  end

  describe "RequireMcpAuth plug execution" do
    test "halts with 401 when token is missing and token is configured", %{conn: conn} do
      conn = RequireMcpAuth.call(conn, [])
      assert conn.halted
      assert conn.status == 401

      decoded = Jason.decode!(conn.resp_body)
      assert decoded["error"]["code"] == -32_600
      assert decoded["error"]["message"] =~ "Missing MCP authentication token"
    end

    test "halts with 401 when token is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> RequireMcpAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "authenticates with Bearer token and assigns default system actor", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@test_token}")
        |> RequireMcpAuth.call([])

      refute conn.halted
      actor = Ash.PlugHelpers.get_actor(conn)
      assert actor != nil
      assert actor.role == :admin
      assert actor.email == "mcp-service@ravner.internal"
    end

    test "authenticates with Bearer token and assigns configured actor email if found", %{
      conn: conn
    } do
      user = user_fixture(%{role: :editor})
      Application.put_env(:ravner, :mcp_actor_email, user.email)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@test_token}")
        |> RequireMcpAuth.call([])

      refute conn.halted
      actor = Ash.PlugHelpers.get_actor(conn)
      assert actor != nil
      assert actor.id == user.id
      assert actor.email == user.email
      assert actor.role == :editor
    end

    test "authenticates with X-API-Key header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-api-key", @test_token)
        |> RequireMcpAuth.call([])

      refute conn.halted
      actor = Ash.PlugHelpers.get_actor(conn)
      assert actor.role == :admin
    end

    test "authenticates with X-MCP-Token header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-mcp-token", @test_token)
        |> RequireMcpAuth.call([])

      refute conn.halted
      actor = Ash.PlugHelpers.get_actor(conn)
      assert actor.role == :admin
    end

    test "authenticates with Basic Auth header", %{conn: conn} do
      encoded = Base.encode64("mcp:#{@test_token}")

      conn =
        conn
        |> put_req_header("authorization", "Basic #{encoded}")
        |> RequireMcpAuth.call([])

      refute conn.halted
      actor = Ash.PlugHelpers.get_actor(conn)
      assert actor.role == :admin
    end

    test "authenticates with user session token", %{conn: conn} do
      user = user_fixture(%{role: :admin})
      session_token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{session_token}")
        |> RequireMcpAuth.call([])

      refute conn.halted
      actor = Ash.PlugHelpers.get_actor(conn)
      assert actor != nil
      assert actor.id == user.id
    end
  end
end
