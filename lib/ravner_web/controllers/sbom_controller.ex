defmodule RavnerWeb.SbomController do
  @moduledoc """
  Controller serving CycloneDX 1.5 Software Bill of Materials (SBOM) JSON downloads
  for individual project repositories and aggregated projects.
  """
  use RavnerWeb, :controller

  alias Ravner.Integrations.VCS
  alias Ravner.Inventory
  alias Ravner.Scans.SbomSerializer

  @cyclonedx_content_type "application/vnd.cyclonedx+json; charset=utf-8"

  @doc """
  Generates and streams a CycloneDX 1.5 SBOM JSON file for a single repository.
  """
  def download_repository(conn, %{"id" => id}) do
    repo = Inventory.get_project_repository!(id)

    case SbomSerializer.generate_for_repository(repo) do
      {:ok, bom} ->
        slug =
          (repo.external_id || VCS.extract_slug_from_url(repo.url) || "repository-#{repo.id}")
          |> sanitize_slug()

        filename = "#{slug}-sbom.cdx.json"
        json = SbomSerializer.to_json!(bom)

        conn
        |> put_resp_content_type(@cyclonedx_content_type)
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
        |> send_resp(200, json)

      {:error, reason} ->
        conn
        |> put_flash(:error, "Failed to generate repository SBOM: #{reason}")
        |> redirect(to: ~p"/admin/repositories")
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_flash(:error, "Repository not found")
      |> redirect(to: ~p"/admin/repositories")
  end

  @doc """
  Generates and streams an aggregated CycloneDX 1.5 SBOM JSON file for an entire project.
  """
  def download_project(conn, %{"id" => id}) do
    project = Inventory.get_project!(id)

    case SbomSerializer.generate_for_project(project) do
      {:ok, bom} ->
        slug = (project.slug || project.name || "project-#{project.id}") |> sanitize_slug()
        filename = "#{slug}-sbom.cdx.json"
        json = SbomSerializer.to_json!(bom)

        conn
        |> put_resp_content_type(@cyclonedx_content_type)
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
        |> send_resp(200, json)

      {:error, reason} ->
        conn
        |> put_flash(:error, "Failed to generate project SBOM: #{reason}")
        |> redirect(to: ~p"/ownership/projects/#{project.id}")
    end
  rescue
    Ash.Error.Query.NotFound ->
      conn
      |> put_flash(:error, "Project not found")
      |> redirect(to: ~p"/ownership")

    Ecto.NoResultsError ->
      conn
      |> put_flash(:error, "Project not found")
      |> redirect(to: ~p"/ownership")
  end

  defp sanitize_slug(str) do
    str
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_\-\.]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end
end
