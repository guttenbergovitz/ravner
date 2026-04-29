defmodule Ravner.Inventory do
  @moduledoc """
  The Inventory context. Manages brands, organizations, people, projects,
  and project roles for domain ownership tracking.
  """

  import Ecto.Query, warn: false
  alias Ravner.Repo

  alias Ravner.Inventory.Brand
  alias Ravner.Inventory.Organization
  alias Ravner.Inventory.Person
  alias Ravner.Inventory.Project
  alias Ravner.Inventory.ProjectRole

  # ── Brands ───────────────────────────────────────────────────────────────────

  def list_brands do
    Repo.all(Brand)
  end

  def get_brand!(id), do: Repo.get!(Brand, id)

  def create_brand(attrs \\ %{}) do
    %Brand{}
    |> Brand.changeset(attrs)
    |> Repo.insert()
  end

  def update_brand(%Brand{} = brand, attrs) do
    brand
    |> Brand.changeset(attrs)
    |> Repo.update()
  end

  def delete_brand(%Brand{} = brand) do
    Repo.delete(brand)
  end

  def change_brand(%Brand{} = brand \\ %Brand{}) do
    Brand.changeset(brand, %{})
  end

  def suggest_brands(query, limit \\ 10) when is_binary(query) and byte_size(query) > 0 do
    pattern = "%#{query}%"

    Brand
    |> where([b], ilike(b.name, ^pattern))
    |> order_by([b], asc: b.name)
    |> limit(^limit)
    |> select([b], %{id: b.id, name: b.name})
    |> Repo.all()
  end

  # ── Organizations ────────────────────────────────────────────────────────────

  def list_organizations do
    Repo.all(Organization) |> Repo.preload([:brand])
  end

  def get_organization!(id), do: Repo.get!(Organization, id) |> Repo.preload([:brand])

  def create_organization(attrs \\ %{}) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert()
  end

  def update_organization(%Organization{} = org, attrs) do
    org
    |> Organization.changeset(attrs)
    |> Repo.update()
  end

  def delete_organization(%Organization{} = org) do
    Repo.delete(org)
  end

  def change_organization(%Organization{} = org \\ %Organization{}) do
    Organization.changeset(org, %{})
  end

  # ── People ───────────────────────────────────────────────────────────────────

  def list_people(opts \\ []) do
    org_id = Keyword.get(opts, :organization_id)

    Person
    |> then(fn q ->
      if org_id, do: where(q, [p], p.organization_id == ^org_id), else: q
    end)
    |> order_by([p], asc: p.last_name, asc: p.first_name)
    |> Repo.all()
    |> Repo.preload([:organization])
  end

  def get_person!(id), do: Repo.get!(Person, id) |> Repo.preload([:organization, :project_roles])

  def create_person(attrs \\ %{}) do
    %Person{}
    |> Person.changeset(attrs)
    |> Repo.insert()
  end

  def update_person(%Person{} = person, attrs) do
    person
    |> Person.changeset(attrs)
    |> Repo.update()
  end

  def delete_person(%Person{} = person) do
    Repo.delete(person)
  end

  def change_person(%Person{} = person \\ %Person{}) do
    Person.changeset(person, %{})
  end

  def suggest_people(query, limit \\ 10) when is_binary(query) and byte_size(query) > 0 do
    pattern = "%#{query}%"

    Person
    |> where([p], ilike(p.last_name, ^pattern) or ilike(p.first_name, ^pattern))
    |> order_by([p], asc: p.last_name, asc: p.first_name)
    |> limit(^limit)
    |> select([p], %{id: p.id, name: fragment("? || ' ' || ?", p.first_name, p.last_name)})
    |> Repo.all()
  end

  # ── Projects ─────────────────────────────────────────────────────────────────

  def list_projects(opts \\ []) do
    org_id = Keyword.get(opts, :organization_id)

    Project
    |> then(fn q ->
      if org_id, do: where(q, [p], p.organization_id == ^org_id), else: q
    end)
    |> order_by([p], asc: p.name)
    |> Repo.all()
    |> Repo.preload([:organization])
  end

  def get_project!(id) do
    Repo.get!(Project, id)
    |> Repo.preload([:organization, :project_roles])
  end

  def create_project(attrs \\ %{}) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def delete_project(%Project{} = project) do
    Repo.delete(project)
  end

  def change_project(%Project{} = project \\ %Project{}) do
    Project.changeset(project, %{})
  end

  def suggest_projects(query, limit \\ 10) when is_binary(query) and byte_size(query) > 0 do
    pattern = "%#{query}%"

    Project
    |> where([p], ilike(p.name, ^pattern))
    |> order_by([p], asc: p.name)
    |> limit(^limit)
    |> select([p], %{id: p.id, name: p.name})
    |> Repo.all()
  end

  # ── Project Roles ────────────────────────────────────────────────────────────

  def list_project_roles(project_id) do
    ProjectRole
    |> where([pr], pr.project_id == ^project_id)
    |> Repo.all()
    |> Repo.preload([:person])
  end

  def list_project_roles_for_person(person_id) do
    ProjectRole
    |> where([pr], pr.person_id == ^person_id)
    |> Repo.all()
    |> Repo.preload([:project])
  end

  def get_project_role!(id), do: Repo.get!(ProjectRole, id) |> Repo.preload([:project, :person])

  def create_project_role(attrs \\ %{}) do
    result =
      %ProjectRole{}
      |> ProjectRole.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, pr} -> {:ok, Repo.preload(pr, [:project, :person])}
      error -> error
    end
  end

  def delete_project_role(%ProjectRole{} = pr) do
    Repo.delete(pr)
  end

  def change_project_role(%ProjectRole{} = pr \\ %ProjectRole{}) do
    ProjectRole.changeset(pr, %{})
  end

  # ── Project Repositories ─────────────────────────────────────────────────────

  alias Ravner.Inventory.ProjectRepository

  def list_project_repositories(project_id) do
    ProjectRepository
    |> where([r], r.project_id == ^project_id)
    |> order_by([r], asc: r.kind, asc: r.id)
    |> Repo.all()
  end

  def get_project_repository!(id), do: Repo.get!(ProjectRepository, id)

  def create_project_repository(attrs \\ %{}) do
    %ProjectRepository{}
    |> ProjectRepository.changeset(attrs)
    |> Repo.insert()
  end

  def update_project_repository(%ProjectRepository{} = repo, attrs) do
    repo
    |> ProjectRepository.changeset(attrs)
    |> Repo.update()
  end

  def delete_project_repository(%ProjectRepository{} = repo) do
    Repo.delete(repo)
  end

  def change_project_repository(%ProjectRepository{} = repo \\ %ProjectRepository{}) do
    ProjectRepository.changeset(repo, %{})
  end

  # ── Dashboard / Ownership counts ─────────────────────────────────────────────

  def count_domains_without_project do
    Repo.aggregate(from(d in Ravner.Domains.Domain, where: is_nil(d.project_id)), :count, :id)
  end

  def count_projects_without_roles do
    Repo.all(
      from(p in Project,
        left_join: pr in ProjectRole,
        on: pr.project_id == p.id,
        group_by: p.id,
        having: count(pr.id) == 0,
        select: count(p.id)
      )
    )
    |> case do
      [cnt] -> cnt
      [] -> 0
    end
  end

  def count_people_without_org do
    Repo.aggregate(from(p in Person, where: is_nil(p.organization_id)), :count, :id)
  end
end
