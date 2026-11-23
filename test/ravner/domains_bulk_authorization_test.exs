defmodule Ravner.DomainsBulkAuthorizationTest do
  use Ravner.DataCase, async: false

  alias Ravner.AccountsFixtures
  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Inventory
  alias Ravner.Repo

  test "bulk delete requires an actor and deletes only domains in actor scope" do
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

    assert {:error, :actor_required} = Domains.bulk_delete([owned_domain.id])
    assert {:ok, 1} = Domains.bulk_delete([owned_domain.id, other_domain.id], actor: manager)
    assert Repo.get(Domain, owned_domain.id) == nil
    assert Repo.get(Domain, other_domain.id) != nil
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp unique_domain(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}.example.com"
end
