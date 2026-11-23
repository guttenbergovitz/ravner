defmodule RavnerWeb.OwnershipLive.OwnershipIndexTest do
  use RavnerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravner.AccountsFixtures
  alias Ravner.Inventory

  setup %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    conn = log_in_user(conn, admin)

    uid = System.unique_integer([:positive])

    {:ok, brand} =
      Inventory.create_brand(
        %{name: "Alpha Corp #{uid}", slug: "alpha-corp-#{uid}"},
        actor: admin
      )

    {:ok, org} =
      Inventory.create_organization(
        %{name: "Alpha Digital #{uid}", slug: "alpha-digital-#{uid}", brand_id: brand.id},
        actor: admin
      )

    {:ok, project} =
      Inventory.create_project(
        %{name: "Alpha Web #{uid}", slug: "alpha-web-#{uid}", organization_id: org.id},
        actor: admin
      )

    {:ok, conn: conn, admin: admin, brand: brand, org: org, project: project}
  end

  describe "Ownership Dashboard (/ownership)" do
    test "renders dashboard with attention alerts for unassigned PM and PO", %{
      conn: conn,
      brand: brand
    } do
      {:ok, _view, html} = live(conn, ~p"/ownership")

      assert html =~ "Ownership"
      assert html =~ brand.name

      # "Needs Attention" sidebar should flag projects without PM and PO
      assert html =~ "Needs Attention"
      assert html =~ "Projects without Project Manager"
      assert html =~ "Projects without Product Owner"
    end
  end
end
