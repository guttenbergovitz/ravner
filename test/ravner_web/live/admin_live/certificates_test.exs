defmodule RavnerWeb.AdminLive.CertificatesTest do
  use RavnerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ravner.Accounts
  alias Ravner.AccountsFixtures
  alias Ravner.Domains
  alias Ravner.DomainsFixtures
  alias Ravner.Repo

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture()
    {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
    conn = log_in_user(conn, admin)
    {:ok, conn: conn, admin: admin}
  end

  describe "SSL Certificates Admin LiveView" do
    test "renders certificate overview and action buttons", %{conn: conn} do
      now = DateTime.utc_now()
      expired_date = DateTime.add(now, -10 * 24 * 3600, :second)
      expiring_soon_date = DateTime.add(now, 15 * 24 * 3600, :second)
      healthy_date = DateTime.add(now, 90 * 24 * 3600, :second)

      d1 = DomainsFixtures.domain_fixture(%{name: "expired-cert.com"})
      d2 = DomainsFixtures.domain_fixture(%{name: "expiring-soon.com"})
      d3 = DomainsFixtures.domain_fixture(%{name: "healthy-cert.com"})

      Domains.upsert_domain_metadata(d1.id, %{
        ssl_valid_until: expired_date,
        ssl_issuer: "Let's Encrypt"
      })

      Domains.upsert_domain_metadata(d2.id, %{
        ssl_valid_until: expiring_soon_date,
        ssl_issuer: "Let's Encrypt"
      })

      Domains.upsert_domain_metadata(d3.id, %{
        ssl_valid_until: healthy_date,
        ssl_issuer: "DigiCert"
      })

      {:ok, view, html} = live(conn, ~p"/admin/certificates")

      assert html =~ "SSL Certificates"
      assert has_element?(view, "#scan-expired-certs")
      assert has_element?(view, "#scan-expiring-30d-certs")
      assert html =~ "expired-cert.com"
      assert html =~ "expiring-soon.com"
      assert html =~ "healthy-cert.com"

      # Click Scan Expired
      result_html = view |> element("#scan-expired-certs") |> render_click()
      assert result_html =~ "Queued SSL scan for 1 expired domain(s)"

      # Click Scan Expiring <= 30d
      result_html = view |> element("#scan-expiring-30d-certs") |> render_click()
      assert result_html =~ "Queued SSL scan for 1 domain(s) expiring within 30 days"
    end
  end
end
