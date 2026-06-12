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
  """
  @spec dashboard_stats() :: map()
  def dashboard_stats do
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
      order_by: [asc: b.name],
      select: %{
        id: b.id,
        name: b.name,
        display_name: b.display_name,
        slug: b.slug,
        notes: b.notes,
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

    %{
      orgs_count: orgs_count,
      projects_count: projects_count,
      people_count: people_count,
      domains_count: domains_count
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
      order_by: [asc: o.name],
      select: %{
        id: o.id,
        name: o.name,
        display_name: o.display_name,
        slug: o.slug,
        type: o.type,
        country: o.country,
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

    %{
      projects_count: projects_count,
      people_count: people_count,
      domains_count: domains_count
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
  Person stats: projects they're involved in.
  """
  @spec person_stats(integer() | String.t()) :: map()
  def person_stats(person_id) do
    person_id = to_integer(person_id)

    roles_count =
      Repo.aggregate(from(pr in ProjectRole, where: pr.person_id == ^person_id), :count, :id)

    %{
      roles_count: roles_count
    }
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
  List domains for a project.
  """
  @spec list_domains_for_project(integer() | String.t()) :: [map()]
  def list_domains_for_project(project_id) do
    project_id = to_integer(project_id)

    from(d in Domain,
      where: d.project_id == ^project_id,
      order_by: [asc: d.name],
      select: %{
        id: d.id,
        name: d.name,
        lifecycle_state: d.lifecycle_state
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
      order_by: [asc: d.name],
      select: %{
        id: d.id,
        name: d.name,
        lifecycle_state: d.lifecycle_state,
        project_id: d.project_id
      }
    )
    |> Repo.all()
  end

  defp to_integer(id) when is_integer(id), do: id
  defp to_integer(id) when is_binary(id), do: String.to_integer(id)
end
