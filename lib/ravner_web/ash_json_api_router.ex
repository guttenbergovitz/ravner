defmodule RavnerWeb.AshJsonApiRouter do
  @moduledoc """
  JSON:API and OpenAPI Router for Ravner enterprise governance resources.

  Exposes standard JSON:API (v1.1) endpoints for:
  - `Ravner.Inventory.Application` (`/applications`)
  - `Ravner.Inventory.Project` (`/projects`)
  - `Ravner.Inventory.Organization` (`/organizations`)
  - `Ravner.Inventory.Brand` (`/brands`)
  - `Ravner.Domains.Domain` (`/domains`)

  Also dynamically derives and serves the OpenAPI 3.0 specification at `/open_api`.
  """
  use AshJsonApi.Router,
    domains: [Ravner.Inventory.AshDomain, Ravner.Domains.AshDomain],
    open_api: "/open_api",
    modify_open_api: {__MODULE__, :modify_open_api, []}

  @doc """
  Customizes the generated OpenAPI specification metadata.
  """
  def modify_open_api(spec, _conn, _opts) do
    vsn = Application.spec(:ravner, :vsn) |> to_string()

    info =
      Map.get(spec, :info) ||
        %OpenApiSpex.Info{
          title: "Ravner Governance & Inventory REST API",
          version: vsn
        }

    updated_info = %{
      info
      | title: "Ravner Governance & Inventory REST API",
        version: vsn,
        description: """
        Machine-to-machine JSON:API (v1.1) and OpenAPI 3.0 contract for Ravner's digital
        landscape, application topology, and infrastructure governance.
        """
    }

    %{spec | info: updated_info}
  end
end
