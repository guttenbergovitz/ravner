defmodule Ravner.Architecture.ArchitectureSerializerTest do
  use ExUnit.Case, async: true

  alias Ravner.Architecture.ArchiMateSerializer
  alias Ravner.Architecture.MermaidSerializer
  alias Ravner.Inventory.Application
  alias Ravner.Inventory.ArchitectureConstraint
  alias Ravner.Inventory.Datastore
  alias Ravner.Inventory.HostingEnvironment
  alias Ravner.Inventory.Project
  alias Ravner.Domains.Domain

  setup do
    host = %HostingEnvironment{id: 1, name: "AWS Frankfurt", provider: "aws"}
    ds = %Datastore{id: 10, name: "Checkout DB", store_type: "postgresql"}
    domain = %Domain{id: 100, name: "shop.example.com"}

    constraint = %ArchitectureConstraint{
      id: 50,
      name: "EAA Accessibility",
      rule_type: "eaa_accessibility_compliance",
      compliance_status: "compliant"
    }

    app = %Application{
      id: 5,
      name: "E-Commerce Web",
      app_type: "storefront",
      criticality: "tier_1",
      hosting_environment: host,
      datastores: [ds],
      domains: [domain],
      constraints: [constraint],
      external_services: []
    }

    project = %Project{
      id: 42,
      name: "Global Commerce",
      project_type: :customer_facing,
      applications: [app]
    }

    {:ok, project: project, app: app}
  end

  test "serializes project to valid Mermaid flowchart", %{project: project} do
    mermaid = MermaidSerializer.serialize_project(project)

    assert is_binary(mermaid)
    assert String.starts_with?(mermaid, "flowchart TB")
    assert mermaid =~ "Global Commerce"
    assert mermaid =~ "E-Commerce Web"
    assert mermaid =~ "shop.example.com"
    assert mermaid =~ "Checkout DB"
    assert mermaid =~ "EAA Accessibility"
    assert mermaid =~ "AWS Frankfurt"
  end

  test "serializes project to valid ArchiMate 3.1 XML format", %{project: project} do
    xml = ArchiMateSerializer.serialize_project(project)

    assert is_binary(xml)
    assert String.starts_with?(xml, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    assert xml =~ "<model xmlns=\"http://www.opengroup.org/xsd/archimate/3.0/\""
    assert xml =~ "identifier=\"model-project-42\""
    assert xml =~ "<element identifier=\"proj-42\" xsi:type=\"WorkPackage\">"
    assert xml =~ "<element identifier=\"app-5\" xsi:type=\"ApplicationComponent\">"
    assert xml =~ "<element identifier=\"domain-100\" xsi:type=\"Artifact\">"
    assert xml =~ "<element identifier=\"ds-10\" xsi:type=\"DataObject\">"
    assert xml =~ "<element identifier=\"constraint-50\" xsi:type=\"Constraint\">"
    assert xml =~ "<element identifier=\"host-1\" xsi:type=\"Node\">"
    assert xml =~ "<relationship identifier=\"rel-proj-app-42-5\""
    assert xml =~ "<relationship identifier=\"rel-app-domain-5-100\""
    assert xml =~ "<relationship identifier=\"rel-app-ds-5-10\""
  end
end
