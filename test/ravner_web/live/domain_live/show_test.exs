defmodule RavnerWeb.DomainLive.ShowTest do
  @moduledoc """
  Tests for the DomainLive.Show page, focusing on the lean security scan UI.
  """
  use RavnerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Ravner.Accounts
  alias Ravner.AccountsFixtures
  alias Ravner.DomainsFixtures
  alias Ravner.Repo

  describe "security scan button" do
    setup %{conn: conn} do
      domain = DomainsFixtures.domain_fixture()
      {:ok, conn: conn, domain: domain}
    end

    test "visible for admin users", %{conn: conn, domain: domain} do
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "button[phx-click='run_security_scan']")
    end

    test "visible for editor users", %{conn: conn, domain: domain} do
      editor = AccountsFixtures.user_fixture()
      {:ok, editor} = editor |> Accounts.User.role_changeset(%{role: :editor}) |> Repo.update()
      conn = log_in_user(conn, editor)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "button[phx-click='run_security_scan']")
    end

    test "hidden for viewer users", %{conn: conn, domain: domain} do
      viewer = AccountsFixtures.user_fixture()
      conn = log_in_user(conn, viewer)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      refute has_element?(view, "button[phx-click='run_security_scan']")
    end

    test "shows security posture section", %{conn: conn, domain: domain} do
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, _view, html} = live(conn, ~p"/domains/#{domain.id}")

      assert html =~ "Security Posture"
    end

    test "renders severity badge row", %{conn: conn, domain: domain} do
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "#severity-badges")
    end

    test "Advanced Tools standalone scan buttons no longer exist", %{conn: conn, domain: domain} do
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      refute has_element?(view, "button[phx-click='scan_naabu']")
      refute has_element?(view, "button[phx-click='scan_nuclei']")
      refute has_element?(view, "button[phx-click='scan_httpx_binary']")
      refute has_element?(view, "button[phx-click='scan_deep']")
    end

    test "shows deep tech scan as an individual scan", %{conn: conn, domain: domain} do
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "#scan-deep-tech")
      assert has_element?(view, "button[phx-click='scan_deep_tech']")
    end

    test "priority lifecycle renders with the same color as the listing", %{conn: conn} do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :priority})
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "#lifecycle-menu-show .bg-teal-600")
    end
  end
end
