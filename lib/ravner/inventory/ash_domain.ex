defmodule Ravner.Inventory.AshDomain do
  @moduledoc """
  The Ash Domain for Inventory entities (Brand, Organization, Project, etc.).
  """
  use Ash.Domain,
    extensions: [AshPaperTrail.Domain, AshAi, AshJsonApi.Domain]

  paper_trail do
    include_versions?(true)
  end

  authorization do
    authorize(:by_default)
  end

  resources do
    resource(Ravner.Inventory.Brand)
    resource(Ravner.Inventory.Organization)
    resource(Ravner.Inventory.Project)
    resource(Ravner.Inventory.ProjectRepository)
    resource(Ravner.Inventory.Person)
    resource(Ravner.Inventory.ProjectRole)
    resource(Ravner.Inventory.Registrar)
    resource(Ravner.Inventory.HostingEnvironment)
    resource(Ravner.Inventory.NetworkAccess)
    resource(Ravner.Inventory.ExternalService)
    resource(Ravner.Inventory.ValueStream)
    resource(Ravner.Inventory.BusinessCapability)
    resource(Ravner.Inventory.ArchitectureConstraint)
    resource(Ravner.Inventory.Datastore)
    resource(Ravner.Inventory.Application)
    resource(Ravner.Inventory.ApplicationValueStream)
    resource(Ravner.Inventory.ApplicationCapability)
    resource(Ravner.Inventory.ApplicationExternalService)
  end

  tools do
    tool(:list_projects, Ravner.Inventory.Project, :read,
      select: [
        :id,
        :name,
        :slug,
        :display_name,
        :description,
        :notes,
        :organization_id,
        :project_manager_id,
        :product_owner_id
      ],
      description: "List inventory projects with organization and manager IDs"
    )

    tool(:get_project, Ravner.Inventory.Project, :read,
      get_by: :id,
      select: [
        :id,
        :name,
        :slug,
        :display_name,
        :description,
        :notes,
        :organization_id,
        :project_manager_id,
        :product_owner_id
      ],
      description: "Get inventory project details by ID"
    )

    tool(:get_project_by_slug, Ravner.Inventory.Project, :read,
      get_by: :slug,
      select: [
        :id,
        :name,
        :slug,
        :display_name,
        :description,
        :notes,
        :organization_id,
        :project_manager_id,
        :product_owner_id
      ],
      description: "Get inventory project details by slug"
    )

    tool(:list_organizations, Ravner.Inventory.Organization, :read,
      select: [:id, :name, :slug, :display_name, :type, :country, :notes, :brand_id, :manager_id],
      description: "List organizations with type and country"
    )

    tool(:get_organization, Ravner.Inventory.Organization, :read,
      get_by: :id,
      select: [:id, :name, :slug, :display_name, :type, :country, :notes, :brand_id, :manager_id],
      description: "Get organization details by ID"
    )

    tool(:list_brands, Ravner.Inventory.Brand, :read,
      select: [:id, :name, :slug, :display_name, :notes, :brand_manager_id],
      description: "List portfolio brands"
    )

    tool(:get_brand, Ravner.Inventory.Brand, :read,
      get_by: :id,
      select: [:id, :name, :slug, :display_name, :notes, :brand_manager_id],
      description: "Get brand details by ID"
    )

    tool(:list_people, Ravner.Inventory.Person, :read,
      select: [
        :id,
        :first_name,
        :last_name,
        :title,
        :email,
        :phone,
        :default_role,
        :organization_id
      ],
      description: "List governance people and contacts"
    )

    tool(:get_person, Ravner.Inventory.Person, :read,
      get_by: :id,
      select: [
        :id,
        :first_name,
        :last_name,
        :title,
        :email,
        :phone,
        :mobile,
        :default_role,
        :notes,
        :organization_id
      ],
      description: "Get person details by ID"
    )

    tool(:list_project_repositories, Ravner.Inventory.ProjectRepository, :read,
      select: [
        :id,
        :url,
        :kind,
        :main_language,
        :technology,
        :project_id,
        :domain_id,
        :scan_status,
        :vulnerability_count
      ],
      description: "List code repositories associated with projects and domains"
    )
  end
end
