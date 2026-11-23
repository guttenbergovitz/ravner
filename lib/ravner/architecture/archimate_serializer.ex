defmodule Ravner.Architecture.ArchiMateSerializer do
  @moduledoc """
  Serializes digital landscape models (BDAT layers: Business, Data, Application, Technology)
  into standard Open Group ArchiMate 3.1 Model Exchange File Format (XML).

  Compatible with ADOIT, Archi, and enterprise EA platforms.
  """

  alias Ravner.Inventory.Project

  @archimate_ns "http://www.opengroup.org/xsd/archimate/3.0/"
  @xsi_ns "http://www.w3.org/2001/XMLSchema-instance"

  @doc """
  Exports an entire Project and its connected digital landscape into ArchiMate 3.1 Exchange XML.
  """
  @spec serialize_project(Project.t()) :: String.t()
  def serialize_project(%Project{} = project) do
    elements = build_elements(project)
    relationships = build_relationships(project)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <model xmlns="#{@archimate_ns}"
           xmlns:xsi="#{@xsi_ns}"
           xsi:schemaLocation="#{@archimate_ns} http://www.opengroup.org/xsd/archimate/3.0/archimate3_Model.xsd"
           identifier="model-project-#{project.id}">
      <name xml:lang="en">#{escape_xml(project.name)} Digital Landscape</name>
      <elements>
    #{Enum.join(elements, "\n")}
      </elements>
      <relationships>
    #{Enum.join(relationships, "\n")}
      </relationships>
    </model>
    """
    |> String.trim()
  end

  defp build_elements(%Project{} = project) do
    project_el =
      "    <element identifier=\"proj-#{project.id}\" xsi:type=\"WorkPackage\"><name xml:lang=\"en\">#{escape_xml(project.name)}</name></element>"

    apps = project.applications || []

    app_elements =
      Enum.flat_map(apps, fn app ->
        app_el =
          "    <element identifier=\"app-#{app.id}\" xsi:type=\"ApplicationComponent\"><name xml:lang=\"en\">#{escape_xml(app.name)}</name><documentation xml:lang=\"en\">Type: #{escape_xml(app.app_type)}, Criticality: #{escape_xml(app.criticality)}</documentation></element>"

        domains =
          Enum.map(app.domains || [], fn d ->
            "    <element identifier=\"domain-#{d.id}\" xsi:type=\"Artifact\"><name xml:lang=\"en\">#{escape_xml(d.name)}</name></element>"
          end)

        datastores =
          Enum.map(app.datastores || [], fn ds ->
            "    <element identifier=\"ds-#{ds.id}\" xsi:type=\"DataObject\"><name xml:lang=\"en\">#{escape_xml(ds.name)}</name><documentation xml:lang=\"en\">Engine: #{escape_xml(ds.store_type)}</documentation></element>"
          end)

        constraints =
          Enum.map(app.constraints || [], fn c ->
            "    <element identifier=\"constraint-#{c.id}\" xsi:type=\"Constraint\"><name xml:lang=\"en\">#{escape_xml(c.name)}</name><documentation xml:lang=\"en\">Rule: #{escape_xml(c.rule_type)}, Status: #{escape_xml(c.compliance_status)}</documentation></element>"
          end)

        hosts =
          if app.hosting_environment do
            [
              "    <element identifier=\"host-#{app.hosting_environment.id}\" xsi:type=\"Node\"><name xml:lang=\"en\">#{escape_xml(app.hosting_environment.name)}</name><documentation xml:lang=\"en\">Provider: #{escape_xml(app.hosting_environment.provider)}</documentation></element>"
            ]
          else
            []
          end

        [app_el] ++ domains ++ datastores ++ constraints ++ hosts
      end)

    [project_el | app_elements]
    |> Enum.uniq_by(fn el ->
      # Dedupe by identifier
      case Regex.run(~r/identifier="([^"]+)"/, el) do
        [_, id] -> id
        _ -> el
      end
    end)
  end

  defp build_relationships(%Project{} = project) do
    apps = project.applications || []

    Enum.flat_map(apps, fn app ->
      proj_rel =
        "    <relationship identifier=\"rel-proj-app-#{project.id}-#{app.id}\" source=\"proj-#{project.id}\" target=\"app-#{app.id}\" xsi:type=\"Realization\" />"

      domain_rels =
        Enum.map(app.domains || [], fn d ->
          "    <relationship identifier=\"rel-app-domain-#{app.id}-#{d.id}\" source=\"app-#{app.id}\" target=\"domain-#{d.id}\" xsi:type=\"Serving\" />"
        end)

      ds_rels =
        Enum.map(app.datastores || [], fn ds ->
          "    <relationship identifier=\"rel-app-ds-#{app.id}-#{ds.id}\" source=\"app-#{app.id}\" target=\"ds-#{ds.id}\" xsi:type=\"Access\" accessType=\"ReadWrite\" />"
        end)

      constraint_rels =
        Enum.map(app.constraints || [], fn c ->
          "    <relationship identifier=\"rel-app-con-#{app.id}-#{c.id}\" source=\"app-#{app.id}\" target=\"constraint-#{c.id}\" xsi:type=\"Influence\" />"
        end)

      host_rels =
        if app.hosting_environment do
          [
            "    <relationship identifier=\"rel-app-host-#{app.id}-#{app.hosting_environment.id}\" source=\"app-#{app.id}\" target=\"host-#{app.hosting_environment.id}\" xsi:type=\"Assignment\" />"
          ]
        else
          []
        end

      [proj_rel] ++ domain_rels ++ ds_rels ++ constraint_rels ++ host_rels
    end)
  end

  defp escape_xml(nil), do: ""
  defp escape_xml(val) when is_atom(val), do: Atom.to_string(val)

  defp escape_xml(val) when is_binary(val) do
    val
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
