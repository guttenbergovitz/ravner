defmodule RavnerWeb.DomainLive.ShowTest do
  @moduledoc """
  Tests for the DomainLive.Show page, focusing on security scan visibility.
  """
  use RavnerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Ravner.Accounts
  alias Ravner.AccountsFixtures
  alias Ravner.DomainsFixtures
  alias Ravner.Repo

  describe "security scan buttons" do
    setup %{conn: conn} do
      domain = DomainsFixtures.domain_fixture()
      {:ok, conn: conn, domain: domain}
    end

    test "visible for admin users", %{conn: conn, domain: domain} do
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      assert has_element?(view, "button[phx-click='scan_naabu']")
      assert has_element?(view, "button[phx-click='scan_nuclei']")
      assert has_element?(view, "button[phx-click='scan_httpx_binary']")
      assert has_element?(view, "button[phx-click='scan_deep']")
    end

    test "hidden for editor users", %{conn: conn, domain: domain} do
      editor = AccountsFixtures.user_fixture()
      {:ok, editor} = editor |> Accounts.User.role_changeset(%{role: :editor}) |> Repo.update()
      conn = log_in_user(conn, editor)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      refute has_element?(view, "button[phx-click='scan_naabu']")
      refute has_element?(view, "button[phx-click='scan_nuclei']")
      refute has_element?(view, "button[phx-click='scan_httpx_binary']")
      refute has_element?(view, "button[phx-click='scan_deep']")
    end

    test "hidden for viewer users", %{conn: conn, domain: domain} do
      viewer = AccountsFixtures.user_fixture()
      conn = log_in_user(conn, viewer)

      {:ok, view, _html} = live(conn, ~p"/domains/#{domain.id}")

      refute has_element?(view, "button[phx-click='scan_naabu']")
      refute has_element?(view, "button[phx-click='scan_nuclei']")
      refute has_element?(view, "button[phx-click='scan_httpx_binary']")
      refute has_element?(view, "button[phx-click='scan_deep']")
    end

    test "shows security scan history", %{conn: conn, domain: domain} do
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()
      conn = log_in_user(conn, admin)

      {:ok, _view, html} = live(conn, ~p"/domains/#{domain.id}")

      assert html =~ "Security Scans"
    end
  end
end
