defmodule Ravner.Notifications.WebhookDispatcher do
  @moduledoc """
  Pure Elixir HTTP webhook dispatcher for enterprise chatops and SIEM alerting.
  Supports Slack Block Kit, Microsoft Teams Adaptive Cards v1.4, Discord Embeds,
  and Generic CloudEvents 1.0 RFC JSON.

  Implements SSRF protection to block access to private/loopback RFC1918 subnets,
  HMAC-SHA256 payload signing, and automatic retries via the `:req` HTTP client.
  """

  require Logger

  @type webhook_type :: :slack | :teams | :discord | :generic | String.t()
  @type event_type :: String.t() | atom()

  @timeout_ms 5_000
  @max_retries 3

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Validates that a URL is a valid HTTP/HTTPS endpoint and does not point to
  internal/private network ranges (SSRF protection).
  """
  @spec validate_url(String.t(), keyword()) :: {:ok, URI.t()} | {:error, String.t()}
  def validate_url(url, opts \\ [])

  def validate_url(url, opts) when is_binary(url) do
    allow_private? =
      Keyword.get(
        opts,
        :allow_private_ips,
        Application.get_env(:ravner, :allow_private_webhooks, false)
      )

    uri = URI.parse(url)

    cond do
      is_nil(uri.scheme) or uri.scheme not in ["http", "https"] ->
        {:error, "URL scheme must be http or https"}

      is_nil(uri.host) or uri.host == "" ->
        {:error, "URL host cannot be blank"}

      allow_private? ->
        {:ok, uri}

      private_host?(uri.host) ->
        {:error, "Private and loopback addresses are not allowed"}

      true ->
        {:ok, uri}
    end
  end

  def validate_url(_, _opts), do: {:error, "Invalid URL"}

  @doc """
  Dispatches an event notification to a webhook endpoint using `:req`.
  Validates URL against SSRF, formats the payload according to `webhook_type`,
  attaches HMAC signatures if a secret is provided, and retries on transient failures.
  """
  @spec dispatch(String.t(), webhook_type(), event_type(), map(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def dispatch(url, webhook_type, event_type, data, opts \\ []) do
    with {:ok, _uri} <- validate_url(url, opts) do
      event_str = to_string(event_type)
      payload = format_payload(webhook_type, event_str, data, opts)
      secret = Keyword.get(opts, :secret)
      body = Jason.encode!(payload)
      headers = build_headers(body, secret, event_str)

      req_opts =
        Keyword.get(
          opts,
          :req_options,
          Application.get_env(:ravner, :webhook_req_options, [])
        )

      req =
        Req.new(
          url: url,
          body: body,
          headers: headers,
          receive_timeout: @timeout_ms,
          connect_options: [timeout: @timeout_ms],
          retry: :transient,
          max_retries: @max_retries
        )
        |> Req.merge(req_opts)

      case Req.post(req) do
        {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
          {:ok, resp}

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          Logger.warning(
            "Webhook delivery to #{url} returned status #{status}: #{inspect(resp_body)}"
          )

          {:error, {:status, status, resp_body}}

        {:error, reason} = err ->
          Logger.warning("Webhook delivery to #{url} failed: #{inspect(reason)}")
          err
      end
    end
  end

  @doc """
  Delivers an event to a recipient record or map containing `webhook_url`,
  `webhook_type`, and optional `secret_header`.
  """
  @spec deliver_event(map(), event_type(), map(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def deliver_event(recipient, event_type, data, opts \\ []) do
    url = recipient.webhook_url
    type = recipient.webhook_type || "generic"
    secret = recipient.secret_header || Keyword.get(opts, :secret)

    merged_opts =
      opts
      |> Keyword.put(:secret, secret)

    dispatch(url, type, event_type, data, merged_opts)
  end

  # ── Payload Formatters ─────────────────────────────────────────────────────

  @doc """
  Formats raw alert data into the specific JSON schema required by the webhook provider.
  """
  @spec format_payload(webhook_type(), String.t(), map(), keyword()) :: map()
  def format_payload(type, event_type, data, opts \\ [])

  def format_payload(type, event_type, data, _opts) when type in [:slack, "slack"] do
    summary = event_summary(event_type, data)
    fields = event_fields(event_type, data)
    color = event_color_hex(event_type)
    ravner_url = Map.get(data, :ravner_url) || Map.get(data, "ravner_url")

    slack_fields =
      Enum.map(fields, fn {label, val} ->
        %{"type" => "mrkdwn", "text" => "*#{label}:*\n#{val}"}
      end)

    blocks = [
      %{
        "type" => "header",
        "text" => %{"type" => "plain_text", "text" => summary, "emoji" => true}
      },
      %{
        "type" => "section",
        "fields" => slack_fields
      }
    ]

    blocks =
      if ravner_url do
        blocks ++
          [
            %{
              "type" => "actions",
              "elements" => [
                %{
                  "type" => "button",
                  "text" => %{"type" => "plain_text", "text" => "View in Ravner", "emoji" => true},
                  "url" => ravner_url
                }
              ]
            }
          ]
      else
        blocks
      end

    %{
      "blocks" => blocks,
      "attachments" => [
        %{
          "color" => color,
          "blocks" => [
            %{
              "type" => "context",
              "elements" => [
                %{
                  "type" => "mrkdwn",
                  "text" =>
                    "Ravner Security Alert • #{DateTime.utc_now() |> DateTime.to_iso8601()}"
                }
              ]
            }
          ]
        }
      ]
    }
  end

  def format_payload(type, event_type, data, _opts) when type in [:teams, "teams"] do
    summary = event_summary(event_type, data)
    fields = event_fields(event_type, data)
    color = event_teams_color(event_type)
    ravner_url = Map.get(data, :ravner_url) || Map.get(data, "ravner_url")

    facts =
      Enum.map(fields, fn {label, val} ->
        %{"title" => "#{label}:", "value" => to_string(val)}
      end)

    actions =
      if ravner_url do
        [
          %{
            "type" => "Action.OpenUrl",
            "title" => "View in Ravner",
            "url" => ravner_url
          }
        ]
      else
        []
      end

    %{
      "type" => "message",
      "attachments" => [
        %{
          "contentType" => "application/vnd.microsoft.card.adaptive",
          "contentUrl" => nil,
          "content" => %{
            "$schema" => "http://adaptivecards.io/schemas/adaptive-card.json",
            "type" => "AdaptiveCard",
            "version" => "1.4",
            "body" => [
              %{
                "type" => "TextBlock",
                "size" => "Medium",
                "weight" => "Bolder",
                "text" => summary,
                "color" => color
              },
              %{
                "type" => "FactSet",
                "facts" => facts
              }
            ],
            "actions" => actions
          }
        }
      ]
    }
  end

  def format_payload(type, event_type, data, _opts) when type in [:discord, "discord"] do
    summary = event_summary(event_type, data)
    fields = event_fields(event_type, data)
    color_int = event_color_int(event_type)
    ravner_url = Map.get(data, :ravner_url) || Map.get(data, "ravner_url")

    discord_fields =
      Enum.map(fields, fn {label, val} ->
        %{"name" => label, "value" => to_string(val), "inline" => true}
      end)

    embed = %{
      "title" => summary,
      "color" => color_int,
      "fields" => discord_fields,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "footer" => %{"text" => "Ravner Security & Uptime"}
    }

    embed = if ravner_url, do: Map.put(embed, "url", ravner_url), else: embed

    %{
      "username" => "Ravner Security",
      "embeds" => [embed]
    }
  end

  def format_payload(_generic, event_type, data, _opts) do
    # Generic CloudEvents 1.0 format
    uuid = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    %{
      "specversion" => "1.0",
      "id" => uuid,
      "source" => "ravner.internal",
      "type" => "io.ravner.alert.#{event_type}",
      "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "datacontenttype" => "application/json",
      "data" => normalize_map_keys(data)
    }
  end

  # ── Headers & Signature ────────────────────────────────────────────────────

  @doc """
  Builds HTTP headers for the outgoing webhook, including user-agent,
  content-type, event type, and HMAC-SHA256 signature if secret is provided.
  """
  @spec build_headers(String.t(), String.t() | nil, String.t()) :: [{String.t(), String.t()}]
  def build_headers(body, secret, event_type) do
    base_headers = [
      {"content-type", "application/json"},
      {"user-agent", "Ravner-Webhook/1.0"},
      {"x-ravner-event", event_type}
    ]

    base_headers
    |> maybe_add_signature(body, secret)
    |> maybe_add_auth_header(secret)
  end

  defp maybe_add_signature(headers, body, secret)
       when is_binary(secret) and secret != "" do
    sig = compute_signature(body, secret)
    [{"x-ravner-signature", sig} | headers]
  end

  defp maybe_add_signature(headers, _body, _secret), do: headers

  defp maybe_add_auth_header(headers, secret)
       when is_binary(secret) and secret != "" do
    if String.starts_with?(secret, "Bearer ") do
      [{"authorization", secret} | headers]
    else
      headers
    end
  end

  defp maybe_add_auth_header(headers, _secret), do: headers

  @doc """
  Computes HMAC-SHA256 signature of the payload string using the provided secret.
  """
  @spec compute_signature(String.t(), String.t()) :: String.t()
  def compute_signature(payload_string, secret) when is_binary(secret) and secret != "" do
    digest =
      :crypto.mac(:hmac, :sha256, secret, payload_string)
      |> Base.encode16(case: :lower)

    "sha256=" <> digest
  end

  # ── SSRF Prevention ────────────────────────────────────────────────────────

  @doc """
  Checks whether a given hostname or IP string corresponds to a private,
  loopback, link-local, or cloud-metadata network address.
  """
  @spec private_host?(String.t()) :: boolean()
  def private_host?(host) when is_binary(host) do
    normalized = String.downcase(String.trim(host))

    cond do
      normalized in ["localhost", "127.0.0.1", "::1", "0.0.0.0"] ->
        true

      String.ends_with?(normalized, ".localhost") or
        String.ends_with?(normalized, ".local") or
        String.ends_with?(normalized, ".internal") or
          String.ends_with?(normalized, ".lan") ->
        true

      match_private_ipv4?(normalized) ->
        true

      match_private_ipv6?(normalized) ->
        true

      true ->
        false
    end
  end

  defp match_private_ipv4?(host) do
    case :inet.parse_ipv4_address(to_charlist(host)) do
      # Loopback
      {:ok, {127, _, _, _}} -> true
      # RFC1918 Class A
      {:ok, {10, _, _, _}} -> true
      # RFC1918 Class B
      {:ok, {172, b, _, _}} when b >= 16 and b <= 31 -> true
      # RFC1918 Class C
      {:ok, {192, 168, _, _}} -> true
      # Link-local / Cloud metadata (169.254.169.254)
      {:ok, {169, 254, _, _}} -> true
      # Current network
      {:ok, {0, _, _, _}} -> true
      _ -> false
    end
  end

  defp match_private_ipv6?(host) do
    case :inet.parse_ipv6_address(to_charlist(host)) do
      # Loopback ::1
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      # Unspecified ::
      {:ok, {0, 0, 0, 0, 0, 0, 0, 0}} -> true
      # Unique local fc00::/7
      {:ok, {w, _, _, _, _, _, _, _}} when w >= 0xFC00 and w <= 0xFDFF -> true
      # Link-local fe80::/10
      {:ok, {w, _, _, _, _, _, _, _}} when Bitwise.band(w, 0xFFC0) == 0xFE80 -> true
      _ -> false
    end
  end

  # ── Event Parsing Helpers ──────────────────────────────────────────────────

  defp event_summary("incident_open", data) do
    name = get_value(data, [:domain_name, "domain_name"], "Target")
    "🚨 Incident Detected: #{name} is DOWN"
  end

  defp event_summary("incident_resolved", data) do
    name = get_value(data, [:domain_name, "domain_name"], "Target")
    "✅ Incident Resolved: #{name} is UP"
  end

  defp event_summary("still_down", data) do
    name = get_value(data, [:domain_name, "domain_name"], "Target")
    seq = get_value(data, [:sequence, "sequence"], 1)
    "⚠️ Still Down: #{name} (Reminder ##{seq})"
  end

  defp event_summary("vulnerability_critical", data) do
    repo = get_value(data, [:repository_name, "repository_name"], "Repository")
    cve = get_value(data, [:cve_id, "cve_id"], "Critical Vulnerability")
    "🔥 Critical Security Vulnerability: #{cve} in #{repo}"
  end

  defp event_summary("secret_leak", data) do
    repo = get_value(data, [:repository_name, "repository_name"], "Repository")
    "🔑 Secret Leak Detected in #{repo}"
  end

  defp event_summary("ssl_expiry", data) do
    name = get_value(data, [:domain_name, "domain_name"], "Domain")
    "🔒 SSL Certificate Expiring Soon: #{name}"
  end

  defp event_summary("test", _data) do
    "🔔 Ravner Webhook Test Notification"
  end

  defp event_summary(other, _data) do
    "📢 Ravner Alert: #{other}"
  end

  defp event_fields("incident_open", data) do
    name = get_value(data, [:domain_name, "domain_name"], "unknown")
    started_at = get_value(data, [:started_at, "started_at"])
    error = get_value(data, [:error, "error"], "Unreachable / Check failed")

    [
      {"Target", name},
      {"Status", "DOWN"},
      {"Started At", format_time(started_at)},
      {"Error", error}
    ]
  end

  defp event_fields("incident_resolved", data) do
    name = get_value(data, [:domain_name, "domain_name"], "unknown")
    ended_at = get_value(data, [:ended_at, "ended_at"])
    duration = get_value(data, [:duration_seconds, "duration_seconds"])

    [
      {"Target", name},
      {"Status", "RECOVERED / UP"},
      {"Recovered At", format_time(ended_at)},
      {"Duration", format_duration(duration)}
    ]
  end

  defp event_fields("still_down", data) do
    name = get_value(data, [:domain_name, "domain_name"], "unknown")
    started_at = get_value(data, [:started_at, "started_at"])
    seq = get_value(data, [:sequence, "sequence"], 1)

    [
      {"Target", name},
      {"Status", "STILL DOWN"},
      {"Downtime Started", format_time(started_at)},
      {"Reminder", "##{seq}"}
    ]
  end

  defp event_fields("vulnerability_critical", data) do
    repo = get_value(data, [:repository_name, "repository_name"], "unknown")
    cve = get_value(data, [:cve_id, "cve_id"], "CVE")
    pkg = get_value(data, [:package_name, "package_name"], "pkg")
    ver = get_value(data, [:package_version, "package_version"], "")

    title =
      get_value(
        data,
        [:title, "title", :summary, "summary"],
        "Critical CVE discovered in dependencies"
      )

    [
      {"Repository", repo},
      {"Severity", "CRITICAL"},
      {"Vulnerability", cve},
      {"Package", "#{pkg} #{ver}"},
      {"Description", title}
    ]
  end

  defp event_fields("secret_leak", data) do
    repo = get_value(data, [:repository_name, "repository_name"], "unknown")
    file_path = get_value(data, [:file_path, "file_path"], "unknown")
    line = get_value(data, [:line_number, "line_number"], 1)
    rule = get_value(data, [:rule_name, "rule_name"], "Hardcoded Secret")
    masked = get_value(data, [:masked_value, "masked_value"], "********")

    [
      {"Repository", repo},
      {"Location", "#{file_path}:#{line}"},
      {"Rule", rule},
      {"Exposed Value", masked}
    ]
  end

  defp event_fields("ssl_expiry", data) do
    name = get_value(data, [:domain_name, "domain_name"], "unknown")
    days = get_value(data, [:days_remaining, "days_remaining"], 0)
    issuer = get_value(data, [:issuer, "issuer"], "Unknown Issuer")
    valid_until = get_value(data, [:valid_until, "valid_until"])

    [
      {"Domain", name},
      {"Days Remaining", "#{days} days"},
      {"Issuer", issuer},
      {"Valid Until", format_time(valid_until)}
    ]
  end

  defp event_fields("test", data) do
    msg =
      get_value(
        data,
        [:message, "message"],
        "Test webhook payload from Ravner enterprise alerting."
      )

    [
      {"Service", "Ravner ASM"},
      {"Status", "Active"},
      {"Timestamp", format_time(DateTime.utc_now())},
      {"Details", msg}
    ]
  end

  defp event_fields(_other, data) do
    Enum.map(data, fn {k, v} ->
      {to_string(k) |> String.replace("_", " ") |> String.capitalize(), inspect(v)}
    end)
    |> Enum.take(5)
  end

  # Slack red
  defp event_color_hex("incident_open"), do: "#E01E5A"
  # Slack green
  defp event_color_hex("incident_resolved"), do: "#2EB67D"
  # Slack amber
  defp event_color_hex("still_down"), do: "#ECB22E"
  defp event_color_hex("vulnerability_critical"), do: "#E01E5A"
  defp event_color_hex("secret_leak"), do: "#E01E5A"
  defp event_color_hex("ssl_expiry"), do: "#ECB22E"
  defp event_color_hex("test"), do: "#2EB67D"
  defp event_color_hex(_), do: "#4A154B"

  # 0xE01E5A
  defp event_color_int("incident_open"), do: 14_687_834
  # 0x2EB67D
  defp event_color_int("incident_resolved"), do: 3_061_373
  # 0xECB22E
  defp event_color_int("still_down"), do: 15_512_110
  defp event_color_int("vulnerability_critical"), do: 14_687_834
  defp event_color_int("secret_leak"), do: 14_687_834
  defp event_color_int("ssl_expiry"), do: 15_512_110
  defp event_color_int("test"), do: 3_061_373
  defp event_color_int(_), do: 4_855_115

  defp event_teams_color("incident_open"), do: "Attention"
  defp event_teams_color("incident_resolved"), do: "Good"
  defp event_teams_color("still_down"), do: "Warning"
  defp event_teams_color("vulnerability_critical"), do: "Attention"
  defp event_teams_color("secret_leak"), do: "Attention"
  defp event_teams_color("ssl_expiry"), do: "Warning"
  defp event_teams_color("test"), do: "Good"
  defp event_teams_color(_), do: "Default"

  defp get_value(map, keys, default \\ nil) when is_map(map) do
    Enum.find_value(keys, default, fn key ->
      case Map.fetch(map, key) do
        {:ok, val} when not is_nil(val) -> val
        _ -> nil
      end
    end)
  end

  defp format_time(nil), do: "N/A"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_time(str) when is_binary(str), do: str
  defp format_time(other), do: inspect(other)

  defp format_duration(nil), do: "N/A"

  defp format_duration(secs) when is_integer(secs) do
    cond do
      secs < 60 -> "#{secs}s"
      secs < 3600 -> "#{div(secs, 60)}m #{rem(secs, 60)}s"
      true -> "#{div(secs, 3600)}h #{div(rem(secs, 3600), 60)}m"
    end
  end

  defp format_duration(other), do: to_string(other)

  defp normalize_map_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, %DateTime{} = v} -> {to_string(k), DateTime.to_iso8601(v)}
      {k, v} when is_map(v) -> {to_string(k), normalize_map_keys(v)}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp normalize_map_keys(other), do: other
end
