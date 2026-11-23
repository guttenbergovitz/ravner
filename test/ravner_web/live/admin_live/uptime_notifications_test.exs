defmodule RavnerWeb.AdminLive.UptimeNotificationsTest do
  use RavnerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ravner.Repo
  alias Ravner.AccountsFixtures
  alias Ravner.Uptime.{NotificationPolicy, NotificationRecipient}

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})

    Application.put_env(:ravner, :webhook_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 200, Jason.encode!(%{ok: true})) end
    )

    on_exit(fn ->
      Application.delete_env(:ravner, :webhook_req_options)
    end)

    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  describe "/admin/uptime/notifications LiveView" do
    test "renders page and tab navigation", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/uptime/notifications")

      assert html =~ "Uptime Notifications"
      assert has_element?(view, "button", "Policies")
      assert has_element?(view, "button", "Groups")
      assert has_element?(view, "button", "Webhooks")
      assert has_element?(view, "button", "Sms")
    end

    test "switches to webhooks tab and renders empty state or list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/uptime/notifications")

      html =
        view
        |> element("button", "Webhooks")
        |> render_click()

      assert html =~ "Configured Webhook Endpoints"
      assert html =~ "Security Alert Triggers"
    end

    test "adds a webhook recipient and displays it", %{conn: conn} do
      policy =
        Repo.insert!(%NotificationPolicy{
          name: "Global Policy",
          scope: "global",
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/uptime/notifications")

      view
      |> form("form[phx-submit='add_recipient']", %{
        "policy_id" => to_string(policy.id),
        "channels" => "webhook",
        "webhook_url" => "https://hooks.slack.com/services/T1/B1/K1",
        "webhook_type" => "slack",
        "secret_header" => "sec_test"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Recipient added."
      assert html =~ "Webhook: slack"
      assert html =~ "https://hooks.slack.com/services/T1/B1/K1"

      # Also check that the recipient appears in the Webhooks tab
      webhooks_html =
        view
        |> element("button", "Webhooks")
        |> render_click()

      assert webhooks_html =~ "https://hooks.slack.com/services/T1/B1/K1"
      assert webhooks_html =~ "1 Connected"
    end

    test "sends a test webhook ping via UI", %{conn: conn} do
      policy =
        Repo.insert!(%NotificationPolicy{
          name: "Test Policy",
          scope: "global",
          enabled: true
        })

      recipient =
        Repo.insert!(%NotificationRecipient{
          policy_id: policy.id,
          channels: "webhook",
          webhook_url: "https://example.com/webhook",
          webhook_type: "generic"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/uptime/notifications")

      # Click the Test button
      html =
        view
        |> element("button[phx-click='test_webhook'][phx-value-id='#{recipient.id}']")
        |> render_click()

      assert html =~ "Test webhook payload delivered successfully (HTTP 200)."
    end

    test "removes a recipient via UI", %{conn: conn} do
      policy =
        Repo.insert!(%NotificationPolicy{
          name: "Delete Policy",
          scope: "global",
          enabled: true
        })

      recipient =
        Repo.insert!(%NotificationRecipient{
          policy_id: policy.id,
          channels: "webhook",
          webhook_url: "https://example.com/to_delete",
          webhook_type: "generic"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/uptime/notifications")

      html =
        view
        |> element("button[phx-click='delete_recipient'][phx-value-id='#{recipient.id}']")
        |> render_click()

      assert html =~ "Removed."
      refute html =~ "https://example.com/to_delete"
      assert Repo.get(NotificationRecipient, recipient.id) == nil
    end
  end
end
