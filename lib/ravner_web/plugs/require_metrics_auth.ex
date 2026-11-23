defmodule RavnerWeb.Plugs.RequireMetricsAuth do
  @moduledoc """
  Plug that guards the `/metrics` endpoint against unauthorized scraping.

  ## Authentication Mechanisms
  1. **HTTP Bearer Token** (standard in Prometheus scrape configs):
     `Authorization: Bearer <TOKEN>`
  2. **HTTP Basic Auth**:
     `Authorization: Basic <base64(user:TOKEN)>`
  3. **Query Parameter** (convenient for ad-hoc browser diagnostics):
     `?token=<TOKEN>`

  ## Security Guarantee
  Token validation uses constant-time string comparison (`Plug.Crypto.secure_compare/2`)
  to prevent timing attacks.

  ## Environment Behavior
  * **Production (`:prod`)**: Access is strictly denied (401) unless `METRICS_BEARER_TOKEN` is configured and matches.
  * **Development & Test (`:dev`, `:test`)**: If `METRICS_BEARER_TOKEN` is not configured, requests are allowed. If configured, validation is enforced.
  """

  import Plug.Conn
  require Logger

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    configured_token = get_configured_token()
    env = Application.fetch_env!(:ravner, :environment)

    cond do
      is_binary(configured_token) and configured_token != "" ->
        if valid_token?(conn, configured_token) do
          conn
        else
          unauthorized(conn, "Invalid or missing metrics authentication token.")
        end

      env == :prod ->
        Logger.error(
          "Access to /metrics blocked: METRICS_BEARER_TOKEN is not configured in production."
        )

        unauthorized(conn, "Metrics authentication token is not configured on this server.")

      true ->
        # Dev and test environments allow unauthenticated access when no token is configured
        conn
    end
  end

  # ── Token Extraction & Verification ────────────────────────────────────────

  defp get_configured_token do
    Application.get_env(:ravner, :metrics_bearer_token) ||
      System.get_env("METRICS_BEARER_TOKEN")
  end

  defp valid_token?(conn, configured_token) do
    provided_token = extract_token(conn)

    is_binary(provided_token) and
      provided_token != "" and
      Plug.Crypto.secure_compare(provided_token, configured_token)
  end

  defp extract_token(conn) do
    # 1. Check Authorization header
    auth_header =
      conn
      |> get_req_header("authorization")
      |> List.first()

    case parse_auth_header(auth_header) do
      {:ok, token} ->
        token

      :error ->
        # 2. Check X-Metrics-Token header
        case get_req_header(conn, "x-metrics-token") do
          [token | _] when token != "" ->
            token

          _ ->
            # 3. Check query param `?token=`
            conn = fetch_query_params(conn)
            conn.query_params["token"]
        end
    end
  end

  defp parse_auth_header("Bearer " <> token), do: {:ok, String.trim(token)}
  defp parse_auth_header("bearer " <> token), do: {:ok, String.trim(token)}

  defp parse_auth_header("Basic " <> encoded) do
    case Base.decode64(String.trim(encoded)) do
      {:ok, decoded} ->
        # Decode user:password -> accept if either matches configured token
        case String.split(decoded, ":", parts: 2) do
          [_user, pass] when pass != "" -> {:ok, pass}
          [token] -> {:ok, token}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_auth_header(_), do: :error

  defp unauthorized(conn, message) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="Ravner Metrics"))
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "# 401 Unauthorized\n# #{message}\n")
    |> halt()
  end
end
