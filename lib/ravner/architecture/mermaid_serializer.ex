defmodule Ravner.Architecture.MermaidSerializer do
  @moduledoc """
  Serializes digital landscape models (Applications, Projects, Value Streams, Infrastructure)
  into ArchiMate 3.1 / UML-compliant Mermaid flowchart diagrams.
  """

  alias Ravner.Inventory.Application
  alias Ravner.Inventory.Project

  @doc """
  Generates a Mermaid flowchart string for a given `Ravner.Inventory.Project` struct,
  visualizing all connected Applications, Datastores, Hosting Nodes, and Domains.
  """
  @spec serialize_project(Project.t()) :: String.t()
  def serialize_project(%Project{} = project) do
    lines = [
      "flowchart TB",
      "  classDef business fill:#e0f2fe,stroke:#0284c7,stroke-width:2px,color:#0369a1,rx:5,ry:5;",
      "  classDef application fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#b45309,rx:5,ry:5;",
      "  classDef tech fill:#f3e8ff,stroke:#9333ea,stroke-width:2px,color:#7e22ce,rx:5,ry:5;",
      "  classDef domain fill:#dcfce7,stroke:#16a34a,stroke-width:2px,color:#15803d,rx:5,ry:5;",
      "  classDef constraint fill:#fee2e2,stroke:#dc2626,stroke-width:2px,color:#b91c1c,rx:5,ry:5;",
      "",
      "  subgraph Project_#{project.id}[\"#{sanitize(project.name)} (#{format_type(project.project_type)})\"]"
    ]

    apps = project.applications || []

    app_lines =
      Enum.flat_map(apps, fn app ->
        serialize_application_subgraph(app)
      end)

    all_lines =
      lines ++
        Enum.map(app_lines, &"    #{&1}") ++
        [
          "  end",
          "  class Project_#{project.id} business"
        ]

    Enum.join(all_lines, "\n")
  end

  @doc """
  Generates a Mermaid flowchart string for a single `Ravner.Inventory.Application` struct.
  """
  @spec serialize_application(Application.t()) :: String.t()
  def serialize_application(%Application{} = app) do
    lines = [
      "flowchart TB",
      "  classDef business fill:#e0f2fe,stroke:#0284c7,stroke-width:2px,color:#0369a1,rx:5,ry:5;",
      "  classDef application fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#b45309,rx:5,ry:5;",
      "  classDef tech fill:#f3e8ff,stroke:#9333ea,stroke-width:2px,color:#7e22ce,rx:5,ry:5;",
      "  classDef domain fill:#dcfce7,stroke:#16a34a,stroke-width:2px,color:#15803d,rx:5,ry:5;",
      "  classDef constraint fill:#fee2e2,stroke:#dc2626,stroke-width:2px,color:#b91c1c,rx:5,ry:5;",
      ""
    ]

    subgraph = serialize_application_subgraph(app)

    Enum.join(lines ++ subgraph, "\n")
  end

  defp serialize_application_subgraph(%Application{} = app) do
    app_node =
      "App_#{app.id}[\"#{sanitize(app.name)} [#{sanitize(app.app_type)}]\\nTier: #{sanitize(app.criticality)}\"]"

    lines = [
      "subgraph Application_#{app.id}[\"Application: #{sanitize(app.name)}\"]",
      "  #{app_node}",
      "  class App_#{app.id} application"
    ]

    # Domains
    domain_lines =
      Enum.flat_map(app.domains || [], fn d ->
        [
          "  Domain_#{d.id}[\"🌐 #{sanitize(d.name)}\"]",
          "  class Domain_#{d.id} domain",
          "  Domain_#{d.id} -.-> App_#{app.id}"
        ]
      end)

    # Datastores
    datastore_lines =
      Enum.flat_map(app.datastores || [], fn ds ->
        [
          "  DS_#{ds.id}[(\"🗄️ #{sanitize(ds.name)}\\n#{sanitize(ds.store_type)}\")]",
          "  class DS_#{ds.id} tech",
          "  App_#{app.id} --> DS_#{ds.id}"
        ]
      end)

    # External Services
    ext_lines =
      Enum.flat_map(app.external_services || [], fn ext ->
        [
          "  Ext_#{ext.id}[\"☁️ #{sanitize(ext.name)}\\n(#{sanitize(ext.service_type)})\"]",
          "  class Ext_#{ext.id} tech",
          "  App_#{app.id} --> Ext_#{ext.id}"
        ]
      end)

    # Constraints (Policy-as-Code)
    constraint_lines =
      Enum.flat_map(app.constraints || [], fn c ->
        icon = if c.compliance_status == "compliant", do: "🛡️", else: "⚠️"

        [
          "  Constraint_#{c.id}[\"#{icon} #{sanitize(c.name)}\\n[#{sanitize(c.rule_type)}]\"]",
          "  class Constraint_#{c.id} constraint",
          "  Constraint_#{c.id} -.- App_#{app.id}"
        ]
      end)

    # Hosting Environment
    host_lines =
      if app.hosting_environment do
        h = app.hosting_environment

        [
          "  Host_#{h.id}[\"🏢 #{sanitize(h.name)} (#{sanitize(h.provider)})\"]",
          "  class Host_#{h.id} tech",
          "  App_#{app.id} --> Host_#{h.id}"
        ]
      else
        []
      end

    lines ++
      domain_lines ++
      datastore_lines ++
      ext_lines ++
      constraint_lines ++
      host_lines ++
      ["end"]
  end

  defp sanitize(nil), do: ""
  defp sanitize(val) when is_atom(val), do: Atom.to_string(val)

  defp sanitize(val) when is_binary(val) do
    val
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", " ")
  end

  defp format_type(nil), do: "Project"

  defp format_type(type),
    do: type |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
