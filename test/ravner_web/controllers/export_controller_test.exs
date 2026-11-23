defmodule RavnerWeb.ExportControllerTest do
  use RavnerWeb.ConnCase, async: false

  alias Ravner.AccountsFixtures
  alias Ravner.Domains
  alias Ravner.Inventory

  test "domain export is restricted to the current scope", %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    manager = AccountsFixtures.user_fixture(%{role: :organization_manager})

    {:ok, organization} =
      Inventory.create_organization(
        %{name: unique_name("owned-org"), slug: unique_name("owned")},
        actor: admin
      )

    {:ok, other_organization} =
      Inventory.create_organization(
        %{name: unique_name("other-org"), slug: unique_name("other")},
        actor: admin
      )

    {:ok, person} =
      Inventory.create_person(
        %{first_name: "Scoped", last_name: "Manager", email: manager.email, user_id: manager.id},
        actor: admin
      )

    {:ok, _organization} =
      Inventory.assign_organization_manager(organization, person.id, actor: admin)

    {:ok, owned_domain} =
      Domains.create_domain(
        %{name: unique_domain("owned"), organization_id: organization.id},
        actor: admin
      )

    {:ok, other_domain} =
      Domains.create_domain(
        %{name: unique_domain("other"), organization_id: other_organization.id},
        actor: admin
      )

    response =
      conn
      |> log_in_user(manager)
      |> get("/domains/export")
      |> response(200)

    assert response =~ owned_domain.name
    refute response =~ other_domain.name
  end

  test "architecture export rejects a project outside the current scope", %{conn: conn} do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    manager = AccountsFixtures.user_fixture(%{role: :project_manager})

    {:ok, organization} =
      Inventory.create_organization(
        %{name: unique_name("arch-org"), slug: unique_name("arch-org")},
        actor: admin
      )

    {:ok, project} =
      Inventory.create_project(
        %{
          name: unique_name("arch-project"),
          slug: unique_name("arch-project"),
          organization_id: organization.id
        },
        actor: admin
      )

    conn =
      conn
      |> log_in_user(manager)
      |> get("/projects/#{project.id}/export/archimate")

    assert conn.status in [403, 404]
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp unique_domain(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}.example.com"
end
