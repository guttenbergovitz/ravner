defmodule Ravner.Inventory.OwnershipStats do
  @moduledoc """
  Aggregated statistics for ownership hierarchy views.
  Provides counts for brands, organizations, projects, people, and domains.
  """

  import Ecto.Query
  alias Ravner.Repo

  alias Ravner.Inventory.Brand
  alias Ravner.Inventory.Organization
  alias Ravner.Inventory.Person
  alias Ravner.Inventory.Project
  alias Ravner.Inventory.ProjectRole
  alias Ravner.Inventory.ProjectRepository
  alias Ravner.Domains.Domain

  @doc """
  Dashboard-level stats: total counts for all entity types.
  Accepts an optional scope map to restrict counts to authorized entities.
  """
  @spec dashboard_stats(map() | nil) :: map()
  def dashboard_stats(scope \\ nil)

  def dashboard_stats(%{global?: false} = scope) do
    org_ids = scope[:organization_ids] || []
    brand_ids = scope[:brand_ids] || []
    project_ids = scope[:project_ids] || []

    people_count =
      if org_ids == [] do
        0
      else
        Repo.aggregate(from(pe in Person, where: pe.organization_id in ^org_ids), :count, :id)
      end

    domains_count =
      cond do
        org_ids == [] and project_ids == [] and brand_ids == [] ->
          0

        true ->
          Repo.aggregate(
            from(d in Domain,
              where:
                d.organization_id in ^org_ids or d.project_id in ^project_ids or
                  d.brand_id in ^brand_ids
            ),
            :count,
            :id
          )
      end

    %{
      brands_count: length(brand_ids),
      organizations_count: length(org_ids),
      projects_count: length(project_ids),
      people_count: people_count,
      domains_count: domains_count
    }
  end

  def dashboard_stats(_scope) do
    %{
      brands_count: Repo.aggregate(Brand, :count, :id),
      organizations_count: Repo.aggregate(Organization, :count, :id),
      projects_count: Repo.aggregate(Project, :count, :id),
      people_count: Repo.aggregate(Person, :count, :id),
      domains_count: Repo.aggregate(Domain, :count, :id)
    }
  end

  @doc """
  List all brands with aggregated stats.
  Returns brands with orgs_count, projects_count, people_count, domains_count.
  """
  @spec list_brands_with_stats() :: [map()]
  def list_brands_with_stats do
    # Subquery for orgs count per brand
    orgs_subq =
      from(o in Organization,
        group_by: o.brand_id,
        select: %{brand_id: o.brand_id, orgs_count: count(o.id)}
      )

    # Subquery for projects count per brand (through orgs)
    projects_subq =
      from(p in Project,
        join: o in Organization,
        on: p.organization_id == o.id,
        group_by: o.brand_id,
        select: %{brand_id: o.brand_id, projects_count: count(p.id)}
      )

    # Subquery for people count per brand (through orgs)
    people_subq =
      from(pe in Person,
        join: o in Organization,
        on: pe.organization_id == o.id,
        group_by: o.brand_id,
        select: %{brand_id: o.brand_id, people_count: count(pe.id)}
      )

    # Subquery for domains count per brand
    domains_subq =
      from(d in Domain,
        where: not is_nil(d.brand_id),
        group_by: d.brand_id,
        select: %{brand_id: d.brand_id, domains_count: count(d.id)}
      )

    from(b in Brand,
      left_join: os in subquery(orgs_subq),
      on: os.brand_id == b.id,
      left_join: ps in subquery(projects_subq),
      on: ps.brand_id == b.id,
      left_join: pes in subquery(people_subq),
      on: pes.brand_id == b.id,
      left_join: ds in subquery(domains_subq),
      on: ds.brand_id == b.id,
      left_join: bm in Person,
      on: b.brand_manager_id == bm.id,
      order_by: [asc: b.name],
      select: %{
        id: b.id,
        name: b.name,
        display_name: b.display_name,
        slug: b.slug,
        notes: b.notes,
        brand_manager_name: fragment("TRIM(CONCAT(? , ' ', ?))", bm.first_name, bm.last_name),
        orgs_count: coalesce(os.orgs_count, 0),
        projects_count: coalesce(ps.projects_count, 0),
        people_count: coalesce(pes.people_count, 0),
        domains_count: coalesce(ds.domains_count, 0)
      }
    )
    |> Repo.all()
  end

  @doc """
  Stats for a single brand.
  """
  @spec brand_stats(integer() | String.t()) :: map()
  def brand_stats(brand_id) do
    brand_id = to_integer(brand_id)

    orgs_count =
      Repo.aggregate(from(o in Organization, where: o.brand_id == ^brand_id), :count, :id)

    projects_count =
      Repo.aggregate(
        from(p in Project,
          join: o in Organization,
          on: p.organization_id == o.id,
          where: o.brand_id == ^brand_id
        ),
        :count,
        :id
      )

    people_count =
      Repo.aggregate(
        from(pe in Person,
          join: o in Organization,
          on: pe.organization_id == o.id,
          where: o.brand_id == ^brand_id
        ),
        :count,
        :id
      )

    domains_count =
      Repo.aggregate(from(d in Domain, where: d.brand_id == ^brand_id), :count, :id)

    sec_summary = Ravner.SecurityScans.portfolio_security_summary(brand_id: brand_id)

    %{
      orgs_count: orgs_count,
      projects_count: projects_count,
      people_count: people_count,
      domains_count: domains_count,
      domains_at_risk_count: sec_summary.domains_at_risk_count,
      critical_count: sec_summary.critical,
      high_count: sec_summary.high,
      medium_count: sec_summary.medium
    }
  end

  @doc """
  List organizations for a brand with stats.
  """
  @spec list_organizations_for_brand(integer() | String.t()) :: [map()]
  def list_organizations_for_brand(brand_id) do
    brand_id = to_integer(brand_id)

    projects_subq =
      from(p in Project,
        group_by: p.organization_id,
        select: %{organization_id: p.organization_id, projects_count: count(p.id)}
      )

    people_subq =
      from(pe in Person,
        group_by: pe.organization_id,
        select: %{organization_id: pe.organization_id, people_count: count(pe.id)}
      )

    domains_subq =
      from(d in Domain,
        where: not is_nil(d.organization_id),
        group_by: d.organization_id,
        select: %{organization_id: d.organization_id, domains_count: count(d.id)}
      )

    from(o in Organization,
      where: o.brand_id == ^brand_id,
      left_join: ps in subquery(projects_subq),
      on: ps.organization_id == o.id,
      left_join: pes in subquery(people_subq),
      on: pes.organization_id == o.id,
      left_join: ds in subquery(domains_subq),
      on: ds.organization_id == o.id,
      left_join: m in Person,
      on: o.manager_id == m.id,
      order_by: [asc: o.name],
      select: %{
        id: o.id,
        name: o.name,
        display_name: o.display_name,
        slug: o.slug,
        type: o.type,
        country: o.country,
        manager_name: fragment("TRIM(CONCAT(? , ' ', ?))", m.first_name, m.last_name),
        projects_count: coalesce(ps.projects_count, 0),
        people_count: coalesce(pes.people_count, 0),
        domains_count: coalesce(ds.domains_count, 0)
      }
    )
    |> Repo.all()
  end

  @doc """
  Stats for a single organization.
  """
  @spec organization_stats(integer() | String.t()) :: map()
  def organization_stats(org_id) do
    org_id = to_integer(org_id)

    projects_count =
      Repo.aggregate(from(p in Project, where: p.organization_id == ^org_id), :count, :id)

    people_count =
      Repo.aggregate(from(pe in Person, where: pe.organization_id == ^org_id), :count, :id)

    domains_count =
      Repo.aggregate(from(d in Domain, where: d.organization_id == ^org_id), :count, :id)

    sec_summary = Ravner.SecurityScans.portfolio_security_summary(organization_id: org_id)

    %{
      projects_count: projects_count,
      people_count: people_count,
      domains_count: domains_count,
      domains_at_risk_count: sec_summary.domains_at_risk_count,
      critical_count: sec_summary.critical,
      high_count: sec_summary.high,
      medium_count: sec_summary.medium
    }
  end

  @doc """
  List projects for an organization with stats.
  """
  @spec list_projects_for_organization(integer() | String.t()) :: [map()]
  def list_projects_for_organization(org_id) do
    org_id = to_integer(org_id)

    roles_subq =
      from(pr in ProjectRole,
        group_by: pr.project_id,
        select: %{project_id: pr.project_id, team_size: count(pr.id)}
      )

    repos_subq =
      from(r in ProjectRepository,
        group_by: r.project_id,
        select: %{project_id: r.project_id, repos_count: count(r.id)}
      )

    domains_subq =
      from(d in Domain,
        where: not is_nil(d.project_id),
        group_by: d.project_id,
        select: %{project_id: d.project_id, domains_count: count(d.id)}
      )

    from(p in Project,
      where: p.organization_id == ^org_id,
      left_join: rs in subquery(roles_subq),
      on: rs.project_id == p.id,
      left_join: rps in subquery(repos_subq),
      on: rps.project_id == p.id,
      left_join: ds in subquery(domains_subq),
      on: ds.project_id == p.id,
      order_by: [asc: p.name],
      select: %{
        id: p.id,
        name: p.name,
        display_name: p.display_name,
        slug: p.slug,
        description: p.description,
        team_size: coalesce(rs.team_size, 0),
        repos_count: coalesce(rps.repos_count, 0),
        domains_count: coalesce(ds.domains_count, 0)
      }
    )
    |> Repo.all()
  end

  @doc """
  Stats for a single project.
  """
  @spec project_stats(integer() | String.t()) :: map()
  def project_stats(project_id) do
    project_id = to_integer(project_id)

    team_size =
      Repo.aggregate(from(pr in ProjectRole, where: pr.project_id == ^project_id), :count, :id)

    repos_count =
      Repo.aggregate(
        from(r in ProjectRepository, where: r.project_id == ^project_id),
        :count,
        :id
      )

    domains_count =
      Repo.aggregate(from(d in Domain, where: d.project_id == ^project_id), :count, :id)

    %{
      team_size: team_size,
      repos_count: repos_count,
      domains_count: domains_count
    }
  end

  @doc """
  List people for an organization with project role counts.
  """
  @spec list_people_for_organization(integer() | String.t()) :: [map()]
  def list_people_for_organization(org_id) do
    org_id = to_integer(org_id)

    roles_subq =
      from(pr in ProjectRole,
        group_by: pr.person_id,
        select: %{person_id: pr.person_id, roles_count: count(pr.id)}
      )

    from(pe in Person,
      where: pe.organization_id == ^org_id,
      left_join: rs in subquery(roles_subq),
      on: rs.person_id == pe.id,
      order_by: [asc: pe.last_name, asc: pe.first_name],
      select: %{
        id: pe.id,
        first_name: pe.first_name,
        last_name: pe.last_name,
        email: pe.email,
        title: pe.title,
        default_role: pe.default_role,
        roles_count: coalesce(rs.roles_count, 0)
      }
    )
    |> Repo.all()
  end

  @doc """
  Person stats: projects, leadership responsibilities, brands and organizations they are involved in.
  """
  @spec person_stats(integer() | String.t()) :: map()
  def person_stats(person_id) do
    person_id = to_integer(person_id)

    roles_count =
      Repo.aggregate(from(pr in ProjectRole, where: pr.person_id == ^person_id), :count, :id)

    pm_projects_count =
      Repo.aggregate(from(p in Project, where: p.project_manager_id == ^person_id), :count, :id)

    po_projects_count =
      Repo.aggregate(from(p in Project, where: p.product_owner_id == ^person_id), :count, :id)

    managed_brands_count =
      Repo.aggregate(from(b in Brand, where: b.brand_manager_id == ^person_id), :count, :id)

    managed_orgs_count =
      Repo.aggregate(from(o in Organization, where: o.manager_id == ^person_id), :count, :id)

    %{
      roles_count: roles_count,
      pm_projects_count: pm_projects_count,
      po_projects_count: po_projects_count,
      managed_brands_count: managed_brands_count,
      managed_orgs_count: managed_orgs_count,
      total_leadership_count:
        pm_projects_count + po_projects_count + managed_brands_count + managed_orgs_count
    }
  end

  @doc """
  List projects managed by a person as Project Manager (Delivery Lead).
  """
  @spec list_pm_projects_for_person(integer() | String.t()) :: [map()]
  def list_pm_projects_for_person(person_id) do
    person_id = to_integer(person_id)

    from(p in Project,
      where: p.project_manager_id == ^person_id,
      join: o in Organization,
      on: p.organization_id == o.id,
      order_by: [asc: p.name],
      select: %{
        project_id: p.id,
        project_name: p.name,
        organization_id: o.id,
        organization_name: o.name
      }
    )
    |> Repo.all()
  end

  @doc """
  List projects represented by a person as Product Owner (Client Lead).
  """
  @spec list_po_projects_for_person(integer() | String.t()) :: [map()]
  def list_po_projects_for_person(person_id) do
    person_id = to_integer(person_id)

    from(p in Project,
      where: p.product_owner_id == ^person_id,
      join: o in Organization,
      on: p.organization_id == o.id,
      order_by: [asc: p.name],
      select: %{
        project_id: p.id,
        project_name: p.name,
        organization_id: o.id,
        organization_name: o.name
      }
    )
    |> Repo.all()
  end

  @doc """
  List brands managed by a person.
  """
  @spec list_brands_for_person(integer() | String.t()) :: [map()]
  def list_brands_for_person(person_id) do
    person_id = to_integer(person_id)

    from(b in Brand,
      where: b.brand_manager_id == ^person_id,
      order_by: [asc: b.name],
      select: %{
        brand_id: b.id,
        brand_name: b.name,
        display_name: b.display_name,
        slug: b.slug
      }
    )
    |> Repo.all()
  end

  @doc """
  List organizations managed by a person.
  """
  @spec list_organizations_for_person(integer() | String.t()) :: [map()]
  def list_organizations_for_person(person_id) do
    person_id = to_integer(person_id)

    from(o in Organization,
      where: o.manager_id == ^person_id,
      order_by: [asc: o.name],
      select: %{
        organization_id: o.id,
        organization_name: o.name,
        display_name: o.display_name,
        slug: o.slug,
        type: o.type
      }
    )
    |> Repo.all()
  end

  @doc """
  List project roles for a person with project details.
  """
  @spec list_roles_for_person(integer() | String.t()) :: [map()]
  def list_roles_for_person(person_id) do
    person_id = to_integer(person_id)

    from(pr in ProjectRole,
      where: pr.person_id == ^person_id,
      join: p in Project,
      on: pr.project_id == p.id,
      join: o in Organization,
      on: p.organization_id == o.id,
      order_by: [asc: p.name],
      select: %{
        id: pr.id,
        role: pr.role,
        project_id: p.id,
        project_name: p.name,
        organization_id: o.id,
        organization_name: o.name
      }
    )
    |> Repo.all()
  end

  @doc """
  List team members for a project.
  """
  @spec list_team_for_project(integer() | String.t()) :: [map()]
  def list_team_for_project(project_id) do
    project_id = to_integer(project_id)

    from(pr in ProjectRole,
      where: pr.project_id == ^project_id,
      join: pe in Person,
      on: pr.person_id == pe.id,
      order_by: [asc: pe.last_name, asc: pe.first_name],
      select: %{
        id: pr.id,
        role: pr.role,
        person_id: pe.id,
        first_name: pe.first_name,
        last_name: pe.last_name,
        email: pe.email,
        title: pe.title
      }
    )
    |> Repo.all()
  end

  @doc """
  List domains for a project with metadata and contact inheritance indicator.
  """
  @spec list_domains_for_project(integer() | String.t()) :: [map()]
  def list_domains_for_project(project_id) do
    project_id = to_integer(project_id)

    from(d in Domain,
      where: d.project_id == ^project_id,
      left_join: m in assoc(d, :domain_metadata),
      order_by: [asc: d.name],
      select: %{
        id: d.id,
        name: d.name,
        lifecycle_state: d.lifecycle_state,
        technical_status: d.technical_status,
        http_status: m.http_status,
        has_custom_contacts?: not is_nil(d.pm_email) or not is_nil(d.po_email)
      }
    )
    |> Repo.all()
  end

  @doc """
  List candidate domains available to assign to a project.
  Searches domains in the same organization or unassigned to any project.
  """
  @spec list_candidate_domains_for_project(
          integer() | String.t(),
          integer() | String.t() | nil,
          String.t()
        ) :: [map()]
  def list_candidate_domains_for_project(project_id, org_id, query \\ "") do
    project_id = to_integer(project_id)
    org_id = if org_id, do: to_integer(org_id), else: nil
    query = String.trim(query)

    base =
      from(d in Domain,
        where: is_nil(d.project_id) or d.project_id != ^project_id
      )

    base =
      if org_id do
        from(d in base, where: is_nil(d.organization_id) or d.organization_id == ^org_id)
      else
        base
      end

    base =
      if query != "" do
        search_pattern = "%#{query}%"
        from(d in base, where: ilike(d.name, ^search_pattern))
      else
        base
      end

    from(d in base,
      order_by: [asc: d.name],
      limit: 25,
      select: %{
        id: d.id,
        name: d.name,
        project_id: d.project_id,
        organization_id: d.organization_id
      }
    )
    |> Repo.all()
  end

  @doc """
  List domains for an organization.
  """
  @spec list_domains_for_organization(integer() | String.t()) :: [map()]
  def list_domains_for_organization(org_id) do
    org_id = to_integer(org_id)

    from(d in Domain,
      where: d.organization_id == ^org_id,
      left_join: p in Project,
      on: d.project_id == p.id,
      order_by: [asc: d.name],
      select: %{
        id: d.id,
        name: d.name,
        lifecycle_state: d.lifecycle_state,
        technical_status: d.technical_status,
        project_id: d.project_id,
        project_name: p.name
      }
    )
    |> Repo.all()
  end

  defp to_integer(id) when is_integer(id), do: id
  defp to_integer(id) when is_binary(id), do: String.to_integer(id)

  @doc """
  List domains directly assigned to a brand.
  """
  @spec list_domains_for_brand(integer() | String.t()) :: [map()]
  def list_domains_for_brand(brand_id) do
    brand_id = to_integer(brand_id)

    from(d in Domain,
      where: d.brand_id == ^brand_id,
      left_join: o in Organization,
      on: d.organization_id == o.id,
      left_join: p in Project,
      on: d.project_id == p.id,
      order_by: [asc: d.name],
      select: %{
        id: d.id,
        name: d.name,
        lifecycle_state: d.lifecycle_state,
        technical_status: d.technical_status,
        organization_id: d.organization_id,
        organization_name: o.name,
        project_id: d.project_id,
        project_name: p.name
      }
    )
    |> Repo.all()
  end

  @doc """
  List projects under a brand (through organizations) with team/repo/domain counts.
  """
  @spec list_projects_for_brand(integer() | String.t()) :: [map()]
  def list_projects_for_brand(brand_id) do
    brand_id = to_integer(brand_id)

    roles_subq =
      from(pr in ProjectRole,
        group_by: pr.project_id,
        select: %{project_id: pr.project_id, team_size: count(pr.id)}
      )

    repos_subq =
      from(r in ProjectRepository,
        group_by: r.project_id,
        select: %{project_id: r.project_id, repos_count: count(r.id)}
      )

    domains_subq =
      from(d in Domain,
        where: not is_nil(d.project_id),
        group_by: d.project_id,
        select: %{project_id: d.project_id, domains_count: count(d.id)}
      )

    from(p in Project,
      join: o in Organization,
      on: p.organization_id == o.id,
      where: o.brand_id == ^brand_id,
      left_join: rs in subquery(roles_subq),
      on: rs.project_id == p.id,
      left_join: rps in subquery(repos_subq),
      on: rps.project_id == p.id,
      left_join: ds in subquery(domains_subq),
      on: ds.project_id == p.id,
      order_by: [asc: o.name, asc: p.name],
      select: %{
        id: p.id,
        name: p.name,
        display_name: p.display_name,
        slug: p.slug,
        description: p.description,
        organization_id: o.id,
        organization_name: o.name,
        team_size: coalesce(rs.team_size, 0),
        repos_count: coalesce(rps.repos_count, 0),
        domains_count: coalesce(ds.domains_count, 0)
      }
    )
    |> Repo.all()
  end

  @doc """
  List people under a brand (through organizations) with role counts.
  """
  @spec list_people_for_brand(integer() | String.t()) :: [map()]
  def list_people_for_brand(brand_id) do
    brand_id = to_integer(brand_id)

    roles_subq =
      from(pr in ProjectRole,
        group_by: pr.person_id,
        select: %{person_id: pr.person_id, roles_count: count(pr.id)}
      )

    from(pe in Person,
      join: o in Organization,
      on: pe.organization_id == o.id,
      where: o.brand_id == ^brand_id,
      left_join: rs in subquery(roles_subq),
      on: rs.person_id == pe.id,
      order_by: [asc: pe.last_name, asc: pe.first_name],
      select: %{
        id: pe.id,
        first_name: pe.first_name,
        last_name: pe.last_name,
        email: pe.email,
        title: pe.title,
        default_role: pe.default_role,
        organization_name: o.name,
        roles_count: coalesce(rs.roles_count, 0)
      }
    )
    |> Repo.all()
  end

  @doc """
  Orphaned/at-risk entity counts for the overview "Needs Attention" panel.
  Accepts an optional scope map to restrict alerts to authorized entities.
  """
  @spec orphaned_stats(map() | nil) :: map()
  def orphaned_stats(scope \\ nil)

  def orphaned_stats(%{global?: false} = scope) do
    brand_ids = scope[:brand_ids] || []
    org_ids = scope[:organization_ids] || []
    project_ids = scope[:project_ids] || []

    domains_without_project =
      if org_ids == [] and brand_ids == [] do
        0
      else
        Repo.aggregate(
          from(d in Domain,
            where:
              is_nil(d.project_id) and
                (d.organization_id in ^org_ids or d.brand_id in ^brand_ids)
          ),
          :count,
          :id
        )
      end

    domains_without_brand =
      if org_ids == [] and project_ids == [] do
        0
      else
        Repo.aggregate(
          from(d in Domain,
            where:
              is_nil(d.brand_id) and
                (d.organization_id in ^org_ids or d.project_id in ^project_ids)
          ),
          :count,
          :id
        )
      end

    empty_organizations =
      if org_ids == [] do
        0
      else
        Repo.aggregate(
          from(o in Organization,
            left_join: p in Project,
            on: p.organization_id == o.id,
            left_join: pe in Person,
            on: pe.organization_id == o.id,
            where: o.id in ^org_ids and is_nil(p.id) and is_nil(pe.id)
          ),
          :count,
          :id
        )
      end

    projects_without_team =
      if project_ids == [] do
        0
      else
        Repo.aggregate(
          from(p in Project,
            left_join: pr in ProjectRole,
            on: pr.project_id == p.id,
            where:
              p.id in ^project_ids and is_nil(pr.id) and
                is_nil(p.project_manager_id) and is_nil(p.product_owner_id)
          ),
          :count,
          :id
        )
      end

    projects_without_pm =
      if project_ids == [] do
        0
      else
        Repo.aggregate(
          from(p in Project,
            where: p.id in ^project_ids and is_nil(p.project_manager_id)
          ),
          :count,
          :id
        )
      end

    projects_without_po =
      if project_ids == [] do
        0
      else
        Repo.aggregate(
          from(p in Project,
            where: p.id in ^project_ids and is_nil(p.product_owner_id)
          ),
          :count,
          :id
        )
      end

    brands_without_manager =
      if brand_ids == [] do
        0
      else
        Repo.aggregate(
          from(b in Brand, where: b.id in ^brand_ids and is_nil(b.brand_manager_id)),
          :count,
          :id
        )
      end

    organizations_without_manager =
      if org_ids == [] do
        0
      else
        Repo.aggregate(
          from(o in Organization, where: o.id in ^org_ids and is_nil(o.manager_id)),
          :count,
          :id
        )
      end

    %{
      domains_without_project: domains_without_project,
      domains_without_brand: domains_without_brand,
      empty_organizations: empty_organizations,
      projects_without_team: projects_without_team,
      projects_without_pm: projects_without_pm,
      projects_without_po: projects_without_po,
      brands_without_manager: brands_without_manager,
      organizations_without_manager: organizations_without_manager
    }
  end

  def orphaned_stats(_scope) do
    %{
      domains_without_project:
        Repo.aggregate(from(d in Domain, where: is_nil(d.project_id)), :count, :id),
      domains_without_brand:
        Repo.aggregate(from(d in Domain, where: is_nil(d.brand_id)), :count, :id),
      empty_organizations:
        Repo.aggregate(
          from(o in Organization,
            left_join: p in Project,
            on: p.organization_id == o.id,
            left_join: pe in Person,
            on: pe.organization_id == o.id,
            where: is_nil(p.id) and is_nil(pe.id)
          ),
          :count,
          :id
        ),
      projects_without_team:
        Repo.aggregate(
          from(p in Project,
            left_join: pr in ProjectRole,
            on: pr.project_id == p.id,
            where: is_nil(pr.id) and is_nil(p.project_manager_id) and is_nil(p.product_owner_id)
          ),
          :count,
          :id
        ),
      projects_without_pm:
        Repo.aggregate(from(p in Project, where: is_nil(p.project_manager_id)), :count, :id),
      projects_without_po:
        Repo.aggregate(from(p in Project, where: is_nil(p.product_owner_id)), :count, :id),
      brands_without_manager:
        Repo.aggregate(from(b in Brand, where: is_nil(b.brand_manager_id)), :count, :id),
      organizations_without_manager:
        Repo.aggregate(from(o in Organization, where: is_nil(o.manager_id)), :count, :id)
    }
  end
end
