defmodule RavnerWeb.Plugs.RequireApiAuth do
  @moduledoc """
  Plug guarding the REST / JSON:API endpoints (`/api/v1/*`).

  ## Purpose & Security Model

  This plug enforces enterprise authentication and fine-grained authorization for HTTP requests.
  It supports:
  1. **Enterprise API Tokens (`Ravner.Accounts.ApiToken`)**:
     - Verified via SHA-256 hash lookup.
     - Enforces lifecycle validity and revocation (`revoked_at`).
     - Enforces **Acceptable Source IP / CIDR** perimeter (`allowed_ips`).
     - Enforces **Request URL Pattern Scoping** (`allowed_paths`).
     - Propagates assigned role (`:viewer`, `:editor`, `:admin`) to Ash policy engine.
     - Asynchronously updates `last_used_at` and `last_used_ip`.
  2. **System Fallback API Key (`RAVNER_API_KEY`)**:
     - Constant-time string matching for backward compatibility.
  3. **User Session Token**:
     - Direct bearer authentication matching active web sessions.
  """

  import Plug.Conn
  import Bitwise
  require Logger

  alias Ravner.Accounts
  alias Ravner.Accounts.ApiToken

  @system_service_actor %Ravner.Accounts.User{
    id: 0,
    role: :admin,
    email: "api-service@ravner.internal",
    name: "API Service Administrator"
  }

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    token_str = extract_token(conn)
    configured_key = get_configured_system_key()
    env = Application.fetch_env!(:ravner, :environment)

    cond do
      conn.request_path == "/api/v1/open_api" ->
        authorize_open_api(conn)

      # 1. Matches an Enterprise API Token
      is_binary(token_str) and String.starts_with?(token_str, "rav_live_") ->
        authenticate_api_token(conn, token_str)

      # 2. Matches configured System Secret API Key
      is_binary(token_str) and is_binary(configured_key) and configured_key != "" and
          Plug.Crypto.secure_compare(token_str, configured_key) ->
        actor = resolve_system_actor()
        Ash.PlugHelpers.set_actor(conn, actor)

      # 3. Matches User Session Token
      is_binary(token_str) and token_str != "" ->
        case resolve_user_by_token(token_str) do
          {:ok, user} ->
            Ash.PlugHelpers.set_actor(conn, user)

          :error ->
            unauthorized(conn, "Invalid API authentication token.")
        end

      # 4. Production unauthenticated rejection
      env == :prod ->
        Logger.warning("Rejected unauthenticated API request in production.")
        unauthorized(conn, "API authentication token is required.")

      # 5. Configured system token missing in dev/test
      is_binary(configured_key) and configured_key != "" ->
        unauthorized(conn, "Missing API authentication token.")

      # 6. Fallback in dev/test
      true ->
        Ash.PlugHelpers.set_actor(conn, @system_service_actor)
    end
  end

  defp authorize_open_api(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{role: :admin} = user} ->
        Ash.PlugHelpers.set_actor(conn, user)

      _ ->
        unauthorized(conn, "Swagger documentation requires an administrator session.")
    end
  end

  # ── API Token Authentication & Scoping ──────────────────────────────────────

  defp authenticate_api_token(conn, token_str) do
    case Accounts.verify_api_token(token_str) do
      {:ok, %ApiToken{} = token} ->
        validate_and_assign_token(conn, token)

      {:error, :revoked} ->
        unauthorized(conn, "API authentication token has been revoked.")

      {:error, :expired} ->
        unauthorized(conn, "API authentication token has expired.")

      {:error, :invalid} ->
        unauthorized(conn, "Invalid API authentication token.")
    end
  end

  defp validate_and_assign_token(conn, %ApiToken{} = token) do
    remote_ip_str = format_remote_ip(conn.remote_ip)

    cond do
      not allowed_ip?(conn.remote_ip, token.allowed_ips) ->
        Logger.warning(
          "API Token '#{token.name}' rejected: IP #{remote_ip_str} not in allowed list."
        )

        forbidden(
          conn,
          "Request IP address #{remote_ip_str} is not authorized for this API token."
        )

      not allowed_path?(conn.method, conn.request_path, token.allowed_paths) ->
        Logger.warning(
          "API Token '#{token.name}' rejected: #{conn.method} #{conn.request_path} not in allowed paths."
        )

        forbidden(
          conn,
          "Access to endpoint '#{conn.method} #{conn.request_path}' is not permitted for this API token."
        )

      true ->
        # Touch usage telemetry
        if Application.fetch_env!(:ravner, :environment) != :test do
          Task.start(fn ->
            Accounts.touch_api_token_usage(token, remote_ip_str)
          end)
        end

        actor = %Ravner.Accounts.User{
          id: token.id,
          role: token.role,
          email: "token:#{token.name}@ravner.internal",
          name: "API Token: #{token.name}"
        }

        Ash.PlugHelpers.set_actor(conn, actor)
    end
  end

  # ── IP / CIDR Matching ──────────────────────────────────────────────────────

  @doc """
  Verifies if a tuple IP address matches an allowed IP/CIDR list.
  If the allowed list is empty, any IP is accepted.
  """
  def allowed_ip?(_remote_ip, nil), do: true
  def allowed_ip?(_remote_ip, []), do: true

  def allowed_ip?(remote_ip, allowed_ips) when is_tuple(remote_ip) and is_list(allowed_ips) do
    remote_ip_str = format_remote_ip(remote_ip)

    Enum.any?(allowed_ips, fn entry ->
      entry = String.trim(entry)

      cond do
        entry == "" ->
          false

        entry == remote_ip_str ->
          true

        String.contains?(entry, "/") ->
          cidr_match?(remote_ip, entry)

        true ->
          false
      end
    end)
  end

  def allowed_ip?(_, _), do: false

  defp cidr_match?(remote_ip, cidr_str) do
    case String.split(cidr_str, "/", parts: 2) do
      [base_str, prefix_str] ->
        with {:ok, base_ip} <- :inet.parse_address(String.to_charlist(base_str)),
             {prefix_len, ""} <- Integer.parse(prefix_str) do
          ip_in_cidr?(remote_ip, base_ip, prefix_len)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp ip_in_cidr?(remote_ip, base_ip, prefix_len)
       when tuple_size(remote_ip) == 4 and tuple_size(base_ip) == 4 and prefix_len in 0..32 do
    {r1, r2, r3, r4} = remote_ip
    {b1, b2, b3, b4} = base_ip
    r_int = (r1 <<< 24) + (r2 <<< 16) + (r3 <<< 8) + r4
    b_int = (b1 <<< 24) + (b2 <<< 16) + (b3 <<< 8) + b4
    mask = if prefix_len == 0, do: 0, else: 0xFFFFFFFF <<< (32 - prefix_len) &&& 0xFFFFFFFF
    (r_int &&& mask) == (b_int &&& mask)
  end

  defp ip_in_cidr?(remote_ip, base_ip, prefix_len)
       when tuple_size(remote_ip) == 8 and tuple_size(base_ip) == 8 and prefix_len in 0..128 do
    # Simple prefix equality for IPv6
    remote_ip == base_ip
  end

  defp ip_in_cidr?(_, _, _), do: false

  defp format_remote_ip(ip) when is_tuple(ip) do
    ip |> :inet.ntoa() |> to_string()
  end

  defp format_remote_ip(_), do: "unknown"

  # ── URL Pattern Matching ───────────────────────────────────────────────────

  @doc """
  Verifies if a method and request path match an allowed paths list.
  If allowed_paths is empty, any path is accepted.
  """
  def allowed_path?(_method, _path, nil), do: true
  def allowed_path?(_method, _path, []), do: true

  def allowed_path?(method, path, allowed_paths) when is_binary(method) and is_binary(path) do
    method_upper = String.upcase(method)

    Enum.any?(allowed_paths, fn pattern ->
      pattern = String.trim(pattern)

      case String.split(pattern, " ", parts: 2) do
        [pattern_method, pattern_path] ->
          String.upcase(pattern_method) == method_upper and match_glob?(path, pattern_path)

        [pattern_path] ->
          match_glob?(path, pattern_path)
      end
    end)
  end

  def allowed_path?(_, _, _), do: false

  defp match_glob?(path, pattern) do
    cond do
      pattern == "*" or pattern == "/*" ->
        true

      String.ends_with?(pattern, "*") ->
        prefix = String.trim_trailing(pattern, "*")
        String.starts_with?(path, prefix)

      true ->
        path == pattern
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp get_configured_system_key do
    Application.get_env(:ravner, :api_key) ||
      System.get_env("RAVNER_API_KEY")
  end

  defp resolve_system_actor do
    configured_email =
      Application.get_env(:ravner, :api_actor_email) ||
        System.get_env("RAVNER_API_ACTOR_EMAIL")

    if is_binary(configured_email) and configured_email != "" do
      case Accounts.get_user_by_email(configured_email) do
        %Ravner.Accounts.User{} = user -> user
        nil -> @system_service_actor
      end
    else
      @system_service_actor
    end
  end

  defp resolve_user_by_token(token) do
    case Accounts.get_user_by_session_token(token) do
      {%Ravner.Accounts.User{} = user, _authenticated_at} ->
        {:ok, user}

      _ ->
        :error
    end
  end

  defp extract_token(conn) do
    auth_header =
      conn
      |> get_req_header("authorization")
      |> List.first()

    case parse_auth_header(auth_header) do
      {:ok, token} ->
        token

      :error ->
        case get_req_header(conn, "x-api-key") do
          [token | _] when token != "" ->
            String.trim(token)

          _ ->
            nil
        end
    end
  end

  defp parse_auth_header(nil), do: :error

  defp parse_auth_header("Bearer " <> token) do
    case String.trim(token) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_auth_header(_), do: :error

  defp unauthorized(conn, message) do
    body =
      Jason.encode!(%{
        errors: [
          %{
            status: "401",
            title: "Unauthorized",
            detail: message
          }
        ]
      })

    conn
    |> put_resp_content_type("application/vnd.api+json")
    |> send_resp(401, body)
    |> halt()
  end

  defp forbidden(conn, message) do
    body =
      Jason.encode!(%{
        errors: [
          %{
            status: "403",
            title: "Forbidden",
            detail: message
          }
        ]
      })

    conn
    |> put_resp_content_type("application/vnd.api+json")
    |> send_resp(403, body)
    |> halt()
  end
end
