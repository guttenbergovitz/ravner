defmodule RavnerWeb.Plugs.RequireMcpAuth do
  @moduledoc """
  Plug guarding the Model Context Protocol (MCP) endpoint (`/mcp`).

  ## Purpose & Security Model

  This plug enforces authentication for all JSON-RPC and HTTP transport requests entering
  the MCP server. Upon successful authentication, it resolves an actor struct and sets it
  on the connection via `Ash.PlugHelpers.set_actor/2`.

  The actor is then automatically propagated by `AshAi.Mcp.Server` into all Ash action
  invocations, ensuring:
  1. Ash policy evaluation (`Ash.Policy.Authorizer`) is strictly enforced per actor role.
  2. Audit tracking (`AshPaperTrail`) logs all mutations attributed to the verified actor.

  ## Supported Authentication Schemes

  1. **HTTP Bearer Token** (`Authorization: Bearer <TOKEN>`)
  2. **API Key Header** (`X-API-Key: <TOKEN>` or `X-MCP-Token: <TOKEN>`)
  3. **HTTP Basic Auth** (`Authorization: Basic <base64(user:TOKEN)>`)

  ## Token Resolution Hierarchy

  - **System MCP Secret**:
    Matches `RAVNER_MCP_API_KEY` (or `:mcp_api_key` in application config) via
    constant-time string comparison (`Plug.Crypto.secure_compare/2`). If matched,
    the actor is resolved from `RAVNER_MCP_ACTOR_EMAIL` or defaults to a dedicated
    system service admin actor (`mcp-service@ravner.internal`).

  - **User Session Token**:
    Matches active user sessions in `Ravner.Accounts` via `get_user_by_session_token/1`.
    The authenticated `%Ravner.Accounts.User{}` is used directly as the Ash actor.

  ## Unauthorized Responses

  Requests failing authentication receive an HTTP 401 response containing a standard
  JSON-RPC 2.0 error payload with code `-32600`.
  """

  import Plug.Conn
  require Logger

  @system_service_actor %Ravner.Accounts.User{
    id: 0,
    role: :admin,
    email: "mcp-service@ravner.internal",
    active: true
  }

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    configured_token = get_configured_token()
    env = Application.fetch_env!(:ravner, :environment)
    provided_token = extract_token(conn)

    cond do
      is_binary(provided_token) and provided_token != "" and
        is_binary(configured_token) and configured_token != "" and
          Plug.Crypto.secure_compare(provided_token, configured_token) ->
        actor = resolve_system_actor()
        Ash.PlugHelpers.set_actor(conn, actor)

      is_binary(provided_token) and provided_token != "" ->
        case resolve_user_by_token(provided_token) do
          {:ok, user} ->
            Ash.PlugHelpers.set_actor(conn, user)

          :error ->
            unauthorized(conn, "Invalid MCP authentication token.")
        end

      env == :prod ->
        Logger.warning("Rejected unauthenticated MCP request in production.")
        unauthorized(conn, "MCP authentication token is required.")

      is_binary(configured_token) and configured_token != "" ->
        unauthorized(conn, "Missing MCP authentication token.")

      true ->
        # In dev or test environments when no token is configured, assign default service actor
        Ash.PlugHelpers.set_actor(conn, @system_service_actor)
    end
  end

  # ── Private Helpers ─────────────────────────────────────────────────────────

  @spec get_configured_token() :: String.t() | nil
  defp get_configured_token do
    Application.get_env(:ravner, :mcp_api_key) ||
      System.get_env("RAVNER_MCP_API_KEY")
  end

  @spec resolve_system_actor() :: Ravner.Accounts.User.t()
  defp resolve_system_actor do
    configured_email =
      Application.get_env(:ravner, :mcp_actor_email) ||
        System.get_env("RAVNER_MCP_ACTOR_EMAIL")

    if is_binary(configured_email) and configured_email != "" do
      case Ravner.Accounts.get_user_by_email(configured_email) do
        %Ravner.Accounts.User{} = user -> user
        nil -> @system_service_actor
      end
    else
      @system_service_actor
    end
  end

  @spec resolve_user_by_token(String.t()) :: {:ok, Ravner.Accounts.User.t()} | :error
  defp resolve_user_by_token(token) do
    case Ravner.Accounts.get_user_by_session_token(token) do
      {%Ravner.Accounts.User{} = user, _authenticated_at} ->
        {:ok, user}

      _ ->
        :error
    end
  end

  @spec extract_token(Plug.Conn.t()) :: String.t() | nil
  defp extract_token(conn) do
    # 1. Authorization header: "Bearer <token>" or "Basic <base64>"
    auth_header =
      conn
      |> get_req_header("authorization")
      |> List.first()

    case parse_auth_header(auth_header) do
      {:ok, token} ->
        token

      :error ->
        # 2. X-API-Key header
        case get_req_header(conn, "x-api-key") do
          [token | _] when token != "" ->
            String.trim(token)

          _ ->
            # 3. X-MCP-Token header
            case get_req_header(conn, "x-mcp-token") do
              [token | _] when token != "" -> String.trim(token)
              _ -> nil
            end
        end
    end
  end

  @spec parse_auth_header(String.t() | nil) :: {:ok, String.t()} | :error
  defp parse_auth_header(nil), do: :error
  defp parse_auth_header("Bearer " <> token) when byte_size(token) == 32, do: {:ok, token}
  defp parse_auth_header("bearer " <> token) when byte_size(token) == 32, do: {:ok, token}
  defp parse_auth_header("Bearer " <> token), do: {:ok, String.trim(token)}
  defp parse_auth_header("bearer " <> token), do: {:ok, String.trim(token)}

  defp parse_auth_header("Basic " <> encoded) do
    case Base.decode64(String.trim(encoded)) do
      {:ok, decoded} ->
        case String.split(decoded, ":", parts: 2) do
          [_user, pass] when pass != "" -> {:ok, pass}
          [token] when token != "" -> {:ok, token}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_auth_header(_), do: :error

  @spec unauthorized(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp unauthorized(conn, message) do
    error_payload = %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{
        "code" => -32_600,
        "message" => "Unauthorized: #{message}"
      }
    }

    conn
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("www-authenticate", ~s(Bearer realm="Ravner MCP Server"))
    |> send_resp(401, Jason.encode!(error_payload))
    |> halt()
  end
end
