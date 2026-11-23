defmodule RavnerWeb.ArchitectureExportController do
  use RavnerWeb, :controller

  alias Ravner.Architecture.ArchiMateSerializer
  alias Ravner.Inventory

  def export_project_archimate(conn, %{"project_id" => project_id}) do
    actor = conn.assigns.current_scope.user

    case Inventory.get_project(project_id, actor: actor) do
      {:ok, project} ->
        xml = ArchiMateSerializer.serialize_project(project)
        filename = "project-#{project.slug || project.id}-archimate.xml"

        conn
        |> put_resp_content_type("application/xml")
        |> put_resp_header("content-disposition", ~s[attachment; filename="#{filename}"])
        |> send_resp(200, xml)

      {:error, _reason} ->
        send_resp(conn, :not_found, "Not found")
    end
  end
end
