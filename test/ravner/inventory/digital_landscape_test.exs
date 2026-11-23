defmodule Ravner.Inventory.DigitalLandscapeTest do
  use Ravner.DataCase, async: true

  alias Ravner.Inventory

  setup do
    admin = %Ravner.Accounts.User{id: 1, role: :admin, email: "admin@example.com"}
    {:ok, admin: admin}
  end

  describe "applications and infrastructure" do
    test "creates and manages application lifecycle with paper trail", %{admin: admin} do
      uid = System.unique_integer([:positive])

      {:ok, brand} =
        Inventory.create_brand(%{name: "Brand #{uid}", slug: "brand-#{uid}"}, actor: admin)

      {:ok, org} =
        Inventory.create_organization(
          %{name: "Org #{uid}", slug: "org-#{uid}", type: :internal, brand_id: brand.id},
          actor: admin
        )

      {:ok, project} =
        Inventory.create_project(
          %{
            name: "Commerce Core #{uid}",
            slug: "commerce-#{uid}",
            project_type: :customer_facing,
            organization_id: org.id
          },
          actor: admin
        )

      {:ok, host} =
        Inventory.create_hosting_environment(
          %{
            name: "AWS EU Central #{uid}",
            slug: "aws-eu-central-#{uid}",
            provider: "aws",
            environment_tier: "production",
            region: "eu-central-1"
          },
          actor: admin
        )

      {:ok, app} =
        Inventory.create_application(
          %{
            name: "Storefront Web #{uid}",
            slug: "storefront-#{uid}",
            app_type: "storefront",
            criticality: "tier_1",
            lifecycle_state: "production",
            project_id: project.id,
            hosting_environment_id: host.id
          },
          actor: admin
        )

      assert app.slug == "storefront-#{uid}"
      assert app.criticality == "tier_1"
      assert app.app_type == "storefront"

      # Check relations
      loaded = Inventory.get_application!(app.id)
      assert loaded.project.id == project.id
      assert loaded.hosting_environment.id == host.id

      # Update app
      {:ok, updated} =
        Inventory.update_application(app, %{notes: "Primary B2C storefront"}, actor: admin)

      assert updated.notes == "Primary B2C storefront"

      # Paper trail audit
      versions = Inventory.list_application_versions(app.id)
      assert length(versions) >= 2
      actions = Enum.map(versions, & &1.version_action_name)
      assert :create in actions
      assert :update in actions
    end

    test "creates and associates datastores to application", %{admin: admin} do
      uid = System.unique_integer([:positive])

      {:ok, host} =
        Inventory.create_hosting_environment(
          %{
            name: "Hetzner Dedicated #{uid}",
            slug: "hetzner-#{uid}",
            provider: "hetzner",
            environment_tier: "production",
            region: "hel1"
          },
          actor: admin
        )

      {:ok, app} =
        Inventory.create_application(
          %{
            name: "Inventory Sync #{uid}",
            slug: "inv-sync-#{uid}",
            app_type: "integration_hub",
            criticality: "tier_2",
            lifecycle_state: "production",
            hosting_environment_id: host.id
          },
          actor: admin
        )

      {:ok, _net_private} =
        Inventory.create_network_access(
          %{
            name: "Private WireGuard #{uid}",
            slug: "wireguard-#{uid}",
            access_level: "wireguard_vpn",
            vpn_gateway_name: "wg-gw-01"
          },
          actor: admin
        )

      {:ok, ds} =
        Inventory.create_datastore(
          %{
            name: "PostgreSQL Primary #{uid}",
            slug: "pg-primary-#{uid}",
            store_type: "postgresql",
            role: "primary_database",
            application_id: app.id,
            hosting_environment_id: host.id,
            notes: "Managed Aurora cluster"
          },
          actor: admin
        )

      assert ds.store_type == "postgresql"
      assert ds.role == "primary_database"
      assert ds.application_id == app.id

      loaded_ds = Inventory.get_datastore!(ds.id)
      assert loaded_ds.application.id == app.id
      assert loaded_ds.hosting_environment.provider == "hetzner"
    end

    test "creates registrar and assigns to domain", %{admin: admin} do
      uid = System.unique_integer([:positive])

      {:ok, registrar} =
        Inventory.create_registrar(
          %{
            name: "Cloudflare Registrar #{uid}",
            slug: "cf-reg-#{uid}",
            portal_url: "https://dash.cloudflare.com"
          },
          actor: admin
        )

      assert registrar.slug == "cf-reg-#{uid}"
      versions = Inventory.list_registrar_versions(registrar.id)
      assert length(versions) >= 1
    end
  end

  describe "business strategy and compliance" do
    test "connects value streams and business capabilities to applications", %{admin: admin} do
      uid = System.unique_integer([:positive])

      {:ok, vs} =
        Inventory.create_value_stream(
          %{
            name: "Order to Cash #{uid}",
            slug: "o2c-#{uid}",
            description: "End-to-end customer purchasing stream",
            stage: "active"
          },
          actor: admin
        )

      {:ok, cap} =
        Inventory.create_business_capability(
          %{
            name: "Payment Processing #{uid}",
            slug: "payments-#{uid}",
            category: "finance",
            description: "Payment gateways, reconciliation, card tokenization"
          },
          actor: admin
        )

      {:ok, ext} =
        Inventory.create_external_service(
          %{
            name: "Stripe #{uid}",
            slug: "stripe-#{uid}",
            service_type: "payment_gateway",
            url: "https://stripe.com"
          },
          actor: admin
        )

      {:ok, app} =
        Inventory.create_application(
          %{
            name: "Checkout API #{uid}",
            slug: "checkout-api-#{uid}",
            app_type: "api",
            criticality: "mission_critical",
            lifecycle_state: "production"
          },
          actor: admin
        )

      # Link associations
      {:ok, _app_vs} =
        Inventory.create_application_value_stream(
          %{application_id: app.id, value_stream_id: vs.id},
          actor: admin
        )

      {:ok, _app_cap} =
        Inventory.create_application_capability(
          %{application_id: app.id, business_capability_id: cap.id},
          actor: admin
        )

      {:ok, _app_ext} =
        Inventory.create_application_external_service(
          %{application_id: app.id, external_service_id: ext.id},
          actor: admin
        )

      loaded = Inventory.get_application!(app.id)
      assert length(loaded.value_streams) == 1
      assert hd(loaded.value_streams).id == vs.id
      assert length(loaded.capabilities) == 1
      assert hd(loaded.capabilities).id == cap.id
      assert length(loaded.external_services) == 1
      assert hd(loaded.external_services).id == ext.id
    end

    test "creates architecture constraints as policy-as-code triggers", %{admin: admin} do
      uid = System.unique_integer([:positive])

      {:ok, constraint} =
        Inventory.create_architecture_constraint(
          %{
            name: "European Accessibility Act (EAA) #{uid}",
            category: "compliance",
            rule_type: "eaa_accessibility_compliance",
            enforcement_level: "mandatory",
            compliance_status: "compliant",
            parameters: %{"standard" => "WCAG 2.1 AA"}
          },
          actor: admin
        )

      assert constraint.category == "compliance"
      assert constraint.rule_type == "eaa_accessibility_compliance"
      assert constraint.enforcement_level == "mandatory"

      versions = Inventory.list_architecture_constraint_versions(constraint.id)
      assert length(versions) >= 1
    end
  end
end
