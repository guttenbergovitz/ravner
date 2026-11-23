defmodule Ravner.NotificationsTest do
  use Ravner.DataCase, async: true

  import Ravner.DomainsFixtures

  alias Ravner.Repo
  alias Ravner.Notifications
  alias Ravner.Uptime.{NotificationPolicy, NotificationRecipient}
  alias Ravner.Inventory.ProjectRepository

  describe "dispatch_security_event/3 and alerts" do
    setup do
      Application.put_env(:ravner, :webhook_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 200, Jason.encode!(%{ok: true})) end
      )

      on_exit(fn ->
        Application.delete_env(:ravner, :webhook_req_options)
      end)

      domain = domain_fixture(%{name: "sec-notify-#{System.unique_integer([:positive])}.com"})

      {:ok, policy} =
        Repo.insert(%NotificationPolicy{
          name: "Global Alert Policy",
          scope: "global",
          enabled: true
        })

      recipient =
        Repo.insert!(%NotificationRecipient{
          policy_id: policy.id,
          channels: "webhook",
          webhook_url: "https://example.com/alerts",
          webhook_type: "slack"
        })

      repo = %ProjectRepository{
        id: 999,
        url: "https://github.com/acme/ravner-core",
        external_id: "acme/ravner-core",
        project_id: 10,
        domain_id: domain.id
      }

      %{domain: domain, policy: policy, recipient: recipient, repo: repo}
    end

    test "dispatch_critical_vulnerabilities enqueues Oban jobs when critical CVEs exist", %{
      repo: repo
    } do
      vulns = [
        %{
          severity: "critical",
          cve_id: "GHSA-1234-abcd",
          package_name: "lodash",
          package_version: "4.17.15",
          title: "Prototype pollution"
        },
        %{
          severity: "low",
          cve_id: "GHSA-5678-efgh",
          package_name: "debug",
          package_version: "2.6.9",
          title: "ReDoS"
        }
      ]

      assert {:ok, [job]} = Notifications.dispatch_critical_vulnerabilities(repo, vulns)
      assert job.args["event_type"] == "vulnerability_critical"
      assert job.args["payload"]["critical_count"] == 1
      assert job.args["payload"]["cve_id"] == "GHSA-1234-abcd"
    end

    test "dispatch_critical_vulnerabilities skips when no critical CVEs exist", %{repo: repo} do
      vulns = [
        %{
          severity: "high",
          cve_id: "GHSA-9999",
          package_name: "express",
          package_version: "4.1.0",
          title: "High severity vuln"
        }
      ]

      assert {:ok, []} = Notifications.dispatch_critical_vulnerabilities(repo, vulns)
    end

    test "dispatch_secret_leaks enqueues Oban jobs for active findings", %{repo: repo} do
      findings = [
        %{
          status: "active",
          file_path: "config/runtime.exs",
          line_number: 12,
          rule_name: "AWS Access Key ID",
          masked_value: "AKIA************9Z1A",
          fingerprint_sha256: "abc123sha"
        },
        %{
          status: "false_positive",
          file_path: "test/fixture.ex",
          line_number: 1,
          rule_name: "Slack Token",
          masked_value: "xoxb************abcd",
          fingerprint_sha256: "fp456sha"
        }
      ]

      assert {:ok, [job]} = Notifications.dispatch_secret_leaks(repo, findings)
      assert job.args["event_type"] == "secret_leak"
      assert job.args["payload"]["leaks_count"] == 1
      assert job.args["payload"]["masked_value"] == "AKIA************9Z1A"
    end

    test "dispatch_secret_leaks skips when no active findings exist", %{repo: repo} do
      findings = [
        %{
          status: "resolved",
          file_path: ".env",
          line_number: 1,
          rule_name: "Database URI",
          masked_value: "postgres://************",
          fingerprint_sha256: "def456sha"
        }
      ]

      assert {:ok, []} = Notifications.dispatch_secret_leaks(repo, findings)
    end

    test "dispatch_ssl_expiry enqueues alert when days <= 14", %{domain: domain} do
      ssl_data = %{
        ssl_days_remaining: 10,
        ssl_issuer: "DigiCert",
        ssl_valid_until: ~U[2026-10-06 12:00:00Z]
      }

      assert {:ok, [job]} = Notifications.dispatch_ssl_expiry(domain.id, domain.name, ssl_data)
      assert job.args["event_type"] == "ssl_expiry"
      assert job.args["payload"]["days_remaining"] == 10
      assert job.args["payload"]["issuer"] == "DigiCert"
    end

    test "dispatch_ssl_expiry ignores when days > 14", %{domain: domain} do
      ssl_data = %{
        ssl_days_remaining: 45,
        ssl_issuer: "Let's Encrypt",
        ssl_valid_until: ~U[2026-11-10 12:00:00Z]
      }

      assert {:ok, []} = Notifications.dispatch_ssl_expiry(domain.id, domain.name, ssl_data)
    end

    test "does not fall back to recipients outside an enabled policy", %{
      domain: domain,
      policy: policy
    } do
      Repo.update!(Ecto.Changeset.change(policy, enabled: false))

      Repo.insert!(%NotificationRecipient{
        channels: "webhook",
        webhook_url: "https://unrelated.example/webhook",
        webhook_type: "generic"
      })

      assert {:ok, []} = Notifications.dispatch_security_event("test", %{domain_id: domain.id})
    end

    test "keeps security alerts unique per recipient", %{
      domain: domain,
      policy: policy,
      recipient: recipient
    } do
      second_recipient =
        Repo.insert!(%NotificationRecipient{
          policy_id: policy.id,
          channels: "webhook",
          webhook_url: "https://second.example/alerts",
          webhook_type: "generic"
        })

      payload = %{domain_id: domain.id, dedup_key: "domain:#{domain.id}:test"}
      assert {:ok, jobs} = Notifications.dispatch_security_event("test", payload)

      assert Enum.map(jobs, & &1.args["recipient_id"]) |> Enum.sort() ==
               Enum.sort([recipient.id, second_recipient.id])

      assert Enum.all?(jobs, fn job -> job.args["dedup_key"] == payload.dedup_key end)
    end

    test "send_test_webhook sends test message", %{recipient: recipient} do
      test_pid = self()

      mock_plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:test_ping_received, Jason.decode!(body)})
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      opts = [
        allow_private_ips: true,
        req_options: [plug: mock_plug]
      ]

      assert {:ok, %Req.Response{status: 200}} = Notifications.send_test_webhook(recipient, opts)
      assert_receive {:test_ping_received, body}
      assert is_list(body["blocks"])
    end
  end
end
