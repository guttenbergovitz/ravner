defmodule Ravner.Notifications.WebhookDispatcherTest do
  use ExUnit.Case, async: true

  alias Ravner.Notifications.WebhookDispatcher

  describe "validate_url/2 and SSRF prevention" do
    test "accepts valid public HTTP/HTTPS URLs" do
      assert {:ok, %URI{host: "hooks.slack.com"}} =
               WebhookDispatcher.validate_url("https://hooks.slack.com/services/T00/B00/X00")

      assert {:ok, %URI{host: "example.com"}} =
               WebhookDispatcher.validate_url("https://example.com/api/webhook")

      assert {:ok, %URI{host: "93.184.216.34"}} =
               WebhookDispatcher.validate_url("http://93.184.216.34/webhook")
    end

    test "rejects non-HTTP/HTTPS schemes" do
      assert {:error, "URL scheme must be http or https"} =
               WebhookDispatcher.validate_url("ftp://example.com/webhook")

      assert {:error, "URL scheme must be http or https"} =
               WebhookDispatcher.validate_url("file:///etc/passwd")

      assert {:error, "URL scheme must be http or https"} =
               WebhookDispatcher.validate_url("gopher://example.com")
    end

    test "rejects blank or malformed URLs" do
      assert {:error, _} = WebhookDispatcher.validate_url("")
      assert {:error, _} = WebhookDispatcher.validate_url("not_a_url")
      assert {:error, _} = WebhookDispatcher.validate_url("http://")
    end

    test "blocks loopback and private IPv4 addresses when allow_private_ips is false" do
      opts = [allow_private_ips: false]

      # Loopback
      assert {:error, "Private and loopback addresses are not allowed"} =
               WebhookDispatcher.validate_url("http://127.0.0.1:4000/webhook", opts)

      assert {:error, "Private and loopback addresses are not allowed"} =
               WebhookDispatcher.validate_url("http://127.0.1.5/webhook", opts)

      # RFC1918 Class A (10.0.0.0/8)
      assert {:error, "Private and loopback addresses are not allowed"} =
               WebhookDispatcher.validate_url("http://10.0.0.1/webhook", opts)

      # RFC1918 Class B (172.16.0.0/12)
      assert {:error, "Private and loopback addresses are not allowed"} =
               WebhookDispatcher.validate_url("http://172.16.0.1/webhook", opts)

      assert {:error, "Private and loopback addresses are not allowed"} =
               WebhookDispatcher.validate_url("http://172.31.255.254/webhook", opts)

      # RFC1918 Class C (192.168.0.0/16)
      assert {:error, "Private and loopback addresses are not allowed"} =
               WebhookDispatcher.validate_url("http://192.168.1.1/webhook", opts)

      # Link-local / Cloud metadata (169.254.169.254)
      assert {:error, "Private and loopback addresses are not allowed"} =
               WebhookDispatcher.validate_url("http://169.254.169.254/latest/meta-data/", opts)

      # Current network (0.0.0.0)
      assert {:error, "Private and loopback addresses are not allowed"} =
               WebhookDispatcher.validate_url("http://0.0.0.0:8000/webhook", opts)
    end

    test "blocks private and localhost hostnames when allow_private_ips is false" do
      opts = [allow_private_ips: false]

      assert {:error, "Private and loopback addresses are not allowed"} =
               WebhookDispatcher.validate_url("http://localhost:4000/webhook", opts)

      assert {:error, "Private and loopback addresses are not allowed"} =
               WebhookDispatcher.validate_url("http://service.local/webhook", opts)

      assert {:error, "Private and loopback addresses are not allowed"} =
               WebhookDispatcher.validate_url("http://vault.internal/webhook", opts)

      assert {:error, "Private and loopback addresses are not allowed"} =
               WebhookDispatcher.validate_url("http://app.localhost/webhook", opts)
    end

    test "permits private addresses when allow_private_ips: true is given" do
      opts = [allow_private_ips: true]

      assert {:ok, %URI{host: "127.0.0.1"}} =
               WebhookDispatcher.validate_url("http://127.0.0.1:4000/webhook", opts)

      assert {:ok, %URI{host: "localhost"}} =
               WebhookDispatcher.validate_url("http://localhost:8080/hook", opts)
    end
  end

  describe "format_payload/4" do
    @test_incident_open %{
      domain_name: "app.example.com",
      domain_id: 42,
      started_at: ~U[2026-09-26 12:00:00Z],
      error: "HTTP 502 Bad Gateway",
      ravner_url: "https://ravner.internal/domains/42"
    }

    test "formats Slack Block Kit payload" do
      payload = WebhookDispatcher.format_payload("slack", "incident_open", @test_incident_open)

      assert %{"blocks" => blocks, "attachments" => [attachment]} = payload

      assert Enum.any?(
               blocks,
               &(&1["type"] == "header" && String.contains?(&1["text"]["text"], "DOWN"))
             )

      assert Enum.any?(blocks, &(&1["type"] == "section"))
      assert Enum.any?(blocks, &(&1["type"] == "actions"))
      assert attachment["color"] == "#E01E5A"
    end

    test "formats MS Teams Adaptive Card payload" do
      payload = WebhookDispatcher.format_payload("teams", "incident_open", @test_incident_open)

      assert %{
               "type" => "message",
               "attachments" => [
                 %{
                   "contentType" => "application/vnd.microsoft.card.adaptive",
                   "content" => %{
                     "version" => "1.4",
                     "body" => [header, factset],
                     "actions" => [action]
                   }
                 }
               ]
             } = payload

      assert header["color"] == "Attention"
      assert factset["type"] == "FactSet"
      assert action["type"] == "Action.OpenUrl"
      assert action["url"] == "https://ravner.internal/domains/42"
    end

    test "formats Discord Embed payload" do
      payload = WebhookDispatcher.format_payload("discord", "incident_open", @test_incident_open)

      assert %{"username" => "Ravner Security", "embeds" => [embed]} = payload
      assert String.contains?(embed["title"], "DOWN")
      assert embed["color"] == 14_687_834
      assert embed["url"] == "https://ravner.internal/domains/42"
      assert is_list(embed["fields"])
    end

    test "formats Generic CloudEvents 1.0 JSON payload" do
      payload = WebhookDispatcher.format_payload("generic", "incident_open", @test_incident_open)

      assert payload["specversion"] == "1.0"
      assert payload["type"] == "io.ravner.alert.incident_open"
      assert payload["source"] == "ravner.internal"
      assert is_binary(payload["id"])
      assert is_binary(payload["time"])
      assert payload["datacontenttype"] == "application/json"
      assert payload["data"]["domain_name"] == "app.example.com"
      assert payload["data"]["error"] == "HTTP 502 Bad Gateway"
    end

    test "formats critical vulnerability alerts" do
      vuln_data = %{
        repository_name: "customer-portal",
        cve_id: "CVE-2026-1234",
        package_name: "express",
        package_version: "4.17.1",
        title: "Remote code execution in query parser"
      }

      slack = WebhookDispatcher.format_payload("slack", "vulnerability_critical", vuln_data)
      assert hd(slack["blocks"])["text"]["text"] =~ "Critical Security Vulnerability"

      teams = WebhookDispatcher.format_payload("teams", "vulnerability_critical", vuln_data)

      assert hd(hd(teams["attachments"])["content"]["body"])["text"] =~
               "Critical Security Vulnerability"
    end

    test "formats secret leak alerts" do
      secret_data = %{
        repository_name: "backend-core",
        file_path: "config/runtime.exs",
        line_number: 45,
        rule_name: "AWS Access Key ID",
        masked_value: "AKIA************4A2F"
      }

      slack = WebhookDispatcher.format_payload("slack", "secret_leak", secret_data)
      assert hd(slack["blocks"])["text"]["text"] =~ "Secret Leak Detected"
    end

    test "formats SSL expiry alerts" do
      ssl_data = %{
        domain_name: "api.example.com",
        days_remaining: 5,
        issuer: "Let's Encrypt",
        valid_until: ~U[2026-10-01 00:00:00Z]
      }

      slack = WebhookDispatcher.format_payload("slack", "ssl_expiry", ssl_data)
      assert hd(slack["blocks"])["text"]["text"] =~ "SSL Certificate Expiring Soon"
    end
  end

  describe "HMAC-SHA256 signature and headers" do
    test "computes valid HMAC-SHA256 signature" do
      body = ~s({"test":true})
      secret = "my_webhook_secret_key"

      sig = WebhookDispatcher.compute_signature(body, secret)
      assert String.starts_with?(sig, "sha256=")

      expected =
        :crypto.mac(:hmac, :sha256, secret, body)
        |> Base.encode16(case: :lower)

      assert sig == "sha256=" <> expected
    end

    test "build_headers includes signature and auth header when secret is provided" do
      body = ~s({"event":"test"})
      headers = WebhookDispatcher.build_headers(body, "my_secret", "incident_open")

      assert {"content-type", "application/json"} in headers
      assert {"user-agent", "Ravner-Webhook/1.0"} in headers
      assert {"x-ravner-event", "incident_open"} in headers

      assert {"x-ravner-signature", sig} =
               Enum.find(headers, fn {k, _} -> k == "x-ravner-signature" end)

      assert String.starts_with?(sig, "sha256=")
    end

    test "build_headers attaches Authorization header when secret starts with Bearer" do
      headers = WebhookDispatcher.build_headers("{}", "Bearer token123", "test")
      assert {"authorization", "Bearer token123"} in headers
    end
  end

  describe "dispatch/5 execution via Req" do
    test "successfully posts payload and returns {:ok, response}" do
      test_pid = self()

      mock_plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:webhook_received, conn.req_headers, Jason.decode!(body)})
        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{status: "received"}))
      end

      opts = [
        allow_private_ips: true,
        secret: "test_secret",
        req_options: [plug: mock_plug]
      ]

      assert {:ok, %Req.Response{status: 200}} =
               WebhookDispatcher.dispatch(
                 "http://localhost:4000/webhook",
                 "slack",
                 "test",
                 %{message: "Testing webhook delivery"},
                 opts
               )

      assert_receive {:webhook_received, headers, body}
      assert is_list(body["blocks"])
      assert Enum.any?(headers, fn {k, _} -> k == "x-ravner-signature" end)
    end

    test "returns {:error, {:status, 500, _}} when endpoint returns error status" do
      mock_plug = fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end

      opts = [
        allow_private_ips: true,
        req_options: [plug: mock_plug, retry: false]
      ]

      assert {:error, {:status, 500, "Internal Server Error"}} =
               WebhookDispatcher.dispatch(
                 "http://localhost:4000/webhook",
                 "generic",
                 "test",
                 %{foo: "bar"},
                 opts
               )
    end
  end
end
