defmodule Ravner.Uptime.NotificationsTest do
  use Ravner.DataCase, async: true

  import Ravner.DomainsFixtures

  alias Ravner.Repo

  alias Ravner.Uptime.{
    Notifications,
    NotificationPolicy,
    NotificationRecipient,
    NotificationDelivery,
    DowntimeWindow
  }

  describe "NotificationRecipient changeset" do
    test "validates allowed channels" do
      attrs = %{channels: "webhook", webhook_url: "https://example.com/webhook"}
      cs = NotificationRecipient.changeset(%NotificationRecipient{}, attrs)
      assert cs.valid?

      attrs_all = %{channels: "all", webhook_url: "https://example.com/webhook"}
      cs_all = NotificationRecipient.changeset(%NotificationRecipient{}, attrs_all)
      assert cs_all.valid?

      attrs_invalid = %{channels: "invalid"}
      cs_invalid = NotificationRecipient.changeset(%NotificationRecipient{}, attrs_invalid)
      refute cs_invalid.valid?
      assert "is invalid" in errors_on(cs_invalid).channels
    end

    test "requires webhook_url when channel is webhook or all" do
      cs = NotificationRecipient.changeset(%NotificationRecipient{}, %{channels: "webhook"})
      refute cs.valid?

      assert "must provide a webhook URL when webhook channel is selected" in errors_on(cs).webhook_url

      cs_all = NotificationRecipient.changeset(%NotificationRecipient{}, %{channels: "all"})
      refute cs_all.valid?

      assert "must provide a webhook URL when webhook channel is selected" in errors_on(cs_all).webhook_url
    end

    test "validates webhook URL scheme and format" do
      cs =
        NotificationRecipient.changeset(%NotificationRecipient{}, %{
          channels: "webhook",
          webhook_url: "ftp://example.com/webhook"
        })

      refute cs.valid?
      assert "URL scheme must be http or https" in errors_on(cs).webhook_url
    end
  end

  describe "deliver_to_recipient/4 with webhook channel" do
    setup do
      domain = domain_fixture(%{name: "webhook-test-#{System.unique_integer([:positive])}.com"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, window} =
        Repo.insert(%DowntimeWindow{
          domain_id: domain.id,
          started_at: DateTime.add(now, -300, :second),
          ended_at: now,
          duration_seconds: 300
        })

      {:ok, policy} =
        Repo.insert(%NotificationPolicy{
          name: "Webhook Domain Policy",
          scope: "domain",
          domain_id: domain.id,
          enabled: true
        })

      %{domain: domain, window: window, policy: policy}
    end

    test "delivers to webhook and records delivery in database", %{
      domain: domain,
      window: window,
      policy: policy
    } do
      test_pid = self()

      mock_plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:webhook_called, conn.req_headers, Jason.decode!(body)})
        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{ok: true}))
      end

      recipient =
        Repo.insert!(%NotificationRecipient{
          policy_id: policy.id,
          channels: "webhook",
          webhook_url: "http://localhost:4000/webhook",
          webhook_type: "slack",
          secret_header: "sec123"
        })

      opts = [
        domain_name: domain.name,
        allow_private_ips: true,
        req_options: [plug: mock_plug]
      ]

      Notifications.deliver_to_recipient(recipient, "incident_resolved", window, opts)

      assert_receive {:webhook_called, _headers, body}
      assert is_list(body["blocks"])

      delivery =
        Repo.get_by(NotificationDelivery,
          downtime_window_id: window.id,
          recipient_id: recipient.id,
          channel: "webhook"
        )

      assert delivery != nil
      assert delivery.event_type == "incident_resolved"
      assert delivery.delivered_at != nil
      assert delivery.error == nil
    end

    test "idempotency prevents duplicate deliveries", %{
      domain: domain,
      window: window,
      policy: policy
    } do
      call_count = :counters.new(1, [:atomics])

      mock_plug = fn conn ->
        :counters.add(call_count, 1, 1)
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      recipient =
        Repo.insert!(%NotificationRecipient{
          policy_id: policy.id,
          channels: "webhook",
          webhook_url: "http://localhost:4000/webhook",
          webhook_type: "generic"
        })

      opts = [
        domain_name: domain.name,
        allow_private_ips: true,
        req_options: [plug: mock_plug]
      ]

      # First delivery
      Notifications.deliver_to_recipient(recipient, "incident_open", window, opts)
      assert :counters.get(call_count, 1) == 1

      # Second delivery with same sequence and window should be skipped
      Notifications.deliver_to_recipient(recipient, "incident_open", window, opts)
      assert :counters.get(call_count, 1) == 1
    end
  end
end
