defmodule RavnerWeb.AdminLive.ProjectLiveTest do
  use RavnerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Ravner.Accounts
  alias Ravner.AccountsFixtures
  alias Ravner.Inventory
  alias Ravner.Repo

  describe "index route" do
    test "renders the project organization name", %{conn: conn} do
      admin = AccountsFixtures.user_fixture()
      {:ok, admin} = admin |> Accounts.User.role_changeset(%{role: :admin}) |> Repo.update()

      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "Acme Org",
            slug: "acme-org",
            type: :internal
          },
          actor: admin
        )

      {:ok, _project} =
        Inventory.create_project(
          %{
            name: "Website",
            slug: "website",
            organization_id: org.id
          },
          actor: admin
        )

      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/admin/projects")

      assert has_element?(view, "td", "Acme Org")
    end
  end
end
