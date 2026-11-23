defmodule RavnerWeb.AdminLive.BreachFindingsLiveTest do
  use RavnerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Ravner.Accounts
  alias Ravner.AccountsFixtures
  alias Ravner.BreachFindingCtx
  alias Ravner.Repo

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture()
    {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
    conn = log_in_user(conn, admin)
    {:ok, conn: conn, admin: admin}
  end

  describe "Breach Findings Admin LiveView" do
    test "renders empty state when no findings", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/breach-findings")

      assert html =~ "Breach Findings"
      assert html =~ "No breach findings detected yet"
    end

    test "renders findings table", %{conn: conn} do
      {:ok, _} =
        BreachFindingCtx.upsert_finding(%{
          domain: "leaked.com",
          title: "Credential exposure",
          severity: "high",
          detail: %{"email" => "user@leaked.com"},
          source: "dehashed"
        })

      {:ok, _} =
        BreachFindingCtx.upsert_finding(%{
          domain: "breached.org",
          title: "Password dump",
          severity: "critical",
          detail: %{},
          source: "haveibeenpwned"
        })

      {:ok, _view, html} = live(conn, ~p"/admin/breach-findings")

      assert html =~ "leaked.com"
      assert html =~ "Credential exposure"
      assert html =~ "high"
      assert html =~ "dehashed"

      assert html =~ "breached.org"
      assert html =~ "Password dump"
      assert html =~ "critical"
    end

    test "can change finding status to resolved", %{conn: conn} do
      {:ok, finding} =
        BreachFindingCtx.upsert_finding(%{
          domain: "test.com",
          title: "Test breach",
          severity: "medium",
          detail: %{},
          source: "test"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/breach-findings")

      html =
        view
        |> element(
          "button[phx-click='set_status'][phx-value-id='#{finding.id}'][phx-value-status='resolved']"
        )
        |> render_click()

      assert html =~ "Status updated to resolved"
    end

    test "can change finding status to false_positive", %{conn: conn} do
      {:ok, finding} =
        BreachFindingCtx.upsert_finding(%{
          domain: "fp.com",
          title: "False positive test",
          severity: "low",
          detail: %{},
          source: "test"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/breach-findings")

      html =
        view
        |> element(
          "button[phx-click='set_status'][phx-value-id='#{finding.id}'][phx-value-status='false_positive']"
        )
        |> render_click()

      assert html =~ "Status updated to false_positive"
    end

    test "can reopen resolved finding", %{conn: conn} do
      {:ok, finding} =
        BreachFindingCtx.upsert_finding(%{
          domain: "reopen.com",
          title: "Reopen test",
          severity: "high",
          detail: %{},
          source: "test"
        })

      {:ok, _} = BreachFindingCtx.set_status(finding.id, "resolved")

      {:ok, view, _html} = live(conn, ~p"/admin/breach-findings")

      html =
        view
        |> element(
          "button[phx-click='set_status'][phx-value-id='#{finding.id}'][phx-value-status='new']"
        )
        |> render_click()

      assert html =~ "Status updated to new"
    end

    test "findings ordered by inserted_at desc", %{conn: conn} do
      {:ok, older} =
        BreachFindingCtx.upsert_finding(%{
          domain: "older.com",
          title: "Older finding",
          severity: "low",
          detail: %{},
          source: "test"
        })

      # Manually backdate older record to ensure ordering
      Ravner.Repo.update_all(
        from(f in Ravner.BreachFinding, where: f.id == ^older.id),
        set: [inserted_at: ~N[2020-01-01 00:00:00]]
      )

      {:ok, _newer} =
        BreachFindingCtx.upsert_finding(%{
          domain: "newer.com",
          title: "Newer finding",
          severity: "high",
          detail: %{},
          source: "test"
        })

      {:ok, _view, html} = live(conn, ~p"/admin/breach-findings")

      # Newer should appear before older in the HTML (desc order)
      newer_pos = :binary.match(html, "newer.com") |> elem(0)
      older_pos = :binary.match(html, "older.com") |> elem(0)
      assert newer_pos < older_pos
    end
  end
end
