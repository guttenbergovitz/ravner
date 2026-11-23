defmodule Ravner.Accounts.ScopeReadCheckTest do
  use Ravner.DataCase, async: false

  alias Ravner.AccountsFixtures
  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Inventory

  test "scoped organization manager can read only domains in managed organization" do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    manager = AccountsFixtures.user_fixture(%{role: :organization_manager})

    {:ok, organization} =
      Inventory.create_organization(%{name: unique_name("owned-org"), slug: unique_name("owned")},
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

    {:ok, domains} = Ash.read(Domain, actor: manager)
    ids = Enum.map(domains, & &1.id)

    assert owned_domain.id in ids
    refute other_domain.id in ids
  end

  test "Ash.read without an actor is forbidden on Domain and child resources" do
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Domain)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Ravner.Domains.DnsRecord)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Ravner.Domains.TechEvidence)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Ravner.Domains.DiscoveredUrl)
  end

  test "child resources (DnsRecord, TechEvidence, DiscoveredUrl) are scoped to actor's domains" do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    manager = AccountsFixtures.user_fixture(%{role: :organization_manager})

    {:ok, organization} =
      Inventory.create_organization(%{name: unique_name("owned-org"), slug: unique_name("owned")},
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

    {:ok, owned_dns} =
      Ravner.Domains.DnsRecord
      |> Ash.Changeset.for_create(
        :create,
        %{domain_id: owned_domain.id, type: "A", value: "1.2.3.4"},
        actor: admin
      )
      |> Ash.create()

    {:ok, other_dns} =
      Ravner.Domains.DnsRecord
      |> Ash.Changeset.for_create(
        :create,
        %{domain_id: other_domain.id, type: "A", value: "5.6.7.8"},
        actor: admin
      )
      |> Ash.create()

    {:ok, dns_records} = Ash.read(Ravner.Domains.DnsRecord, actor: manager)
    dns_ids = Enum.map(dns_records, & &1.id)

    assert owned_dns.id in dns_ids
    refute other_dns.id in dns_ids
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp unique_domain(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}.example.com"
end
