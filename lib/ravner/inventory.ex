defmodule Ravner.Inventory do
  @moduledoc """
  The Inventory context. Manages brands, organizations, people, projects,
  and project roles for domain ownership tracking.
  """

  require Logger

  import Ecto.Query, warn: false
  alias Ravner.Repo

  alias Ravner.Inventory.Brand
  alias Ravner.Inventory.Organization
  alias Ravner.Inventory.Person
  alias Ravner.Inventory.Project
  alias Ravner.Inventory.ProjectRepository
  alias Ravner.Inventory.ProjectRole

  # ── Brands ───────────────────────────────────────────────────────────────────

  @spec list_brands() :: [Brand.t()]
  def list_brands do
    Repo.all(Brand)
  end

  @spec get_brand!(integer() | String.t()) :: Brand.t()
  def get_brand!(id), do: Repo.get!(Brand, id)

  @spec create_brand(map(), keyword()) :: {:ok, Brand.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_brand(attrs \\ %{}, opts \\ []) do
    execute_ash_action(Brand, :create, attrs, opts, Brand.changeset(%Brand{}, attrs))
  end

  @spec update_brand(Brand.t(), map(), keyword()) ::
          {:ok, Brand.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_brand(%Brand{} = brand, attrs, opts \\ []) do
    execute_ash_action(brand, :update, attrs, opts, Brand.changeset(brand, attrs))
  end

  @spec delete_brand(Brand.t(), keyword()) ::
          {:ok, Brand.t()} | {:error, Ecto.Changeset.t() | atom()}
  def delete_brand(%Brand{} = brand, opts \\ []) do
    execute_ash_action(brand, :destroy, %{}, opts, Brand.changeset(brand, %{}))
  end

  @spec change_brand(Brand.t()) :: Ecto.Changeset.t()
  def change_brand(%Brand{} = brand \\ %Brand{}) do
    Brand.changeset(brand, %{})
  end

  @spec suggest_brands(String.t(), pos_integer()) :: [%{id: integer(), name: String.t()}]
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

  @spec list_organizations() :: [Organization.t()]
  def list_organizations do
    Organization |> Ash.read!() |> Ash.load!([:brand])
  end

  @spec get_organization!(integer() | String.t()) :: Organization.t()
  def get_organization!(id), do: Organization |> Ash.get!(id) |> Ash.load!([:brand])

  @spec create_organization(map(), keyword()) ::
          {:ok, Organization.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_organization(attrs \\ %{}, opts \\ []) do
    execute_ash_action(
      Organization,
      :create,
      attrs,
      opts,
      Organization.changeset(%Organization{}, attrs)
    )
  end

  @spec update_organization(Organization.t(), map(), keyword()) ::
          {:ok, Organization.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_organization(%Organization{} = org, attrs, opts \\ []) do
    execute_ash_action(org, :update, attrs, opts, Organization.changeset(org, attrs))
  end

  @spec delete_organization(Organization.t(), keyword()) ::
          {:ok, Organization.t()} | {:error, Ecto.Changeset.t() | atom()}
  def delete_organization(%Organization{} = org, opts \\ []) do
    execute_ash_action(org, :destroy, %{}, opts, Organization.changeset(org, %{}))
  end

  @spec change_organization(Organization.t()) :: Ecto.Changeset.t()
  def change_organization(%Organization{} = org \\ %Organization{}) do
    Organization.changeset(org, %{})
  end

  # ── People ───────────────────────────────────────────────────────────────────

  @spec list_people(keyword()) :: [Person.t()]
  def list_people(opts \\ []) do
    org_id = Keyword.get(opts, :organization_id)

    Person
    |> then(fn q ->
      if org_id, do: where(q, [p], p.organization_id == ^org_id), else: q
    end)
    |> order_by([p], asc: p.last_name, asc: p.first_name)
    |> Repo.all()
    |> Ash.load!([:organization])
  end

  @spec get_person!(integer() | String.t()) :: Person.t()
  def get_person!(id), do: Person |> Ash.get!(id) |> Ash.load!([:organization, :project_roles])

  @spec create_person(map(), keyword()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_person(attrs \\ %{}, opts \\ []) do
    execute_ash_action(Person, :create, attrs, opts, Person.changeset(%Person{}, attrs))
  end

  @spec update_person(Person.t(), map(), keyword()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_person(%Person{} = person, attrs, opts \\ []) do
    execute_ash_action(person, :update, attrs, opts, Person.changeset(person, attrs))
  end

  @spec delete_person(Person.t(), keyword()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t() | atom()}
  def delete_person(%Person{} = person, opts \\ []) do
    execute_ash_action(person, :destroy, %{}, opts, Person.changeset(person, %{}))
  end

  @spec change_person(Person.t()) :: Ecto.Changeset.t()
  def change_person(%Person{} = person \\ %Person{}) do
    Person.changeset(person, %{})
  end

  @spec suggest_people(String.t(), pos_integer()) :: [%{id: integer(), name: String.t()}]
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

  @spec list_projects(keyword()) :: [Project.t()]
  def list_projects(opts \\ []) do
    org_id = Keyword.get(opts, :organization_id)

    Project
    |> then(fn q ->
      if org_id, do: where(q, [p], p.organization_id == ^org_id), else: q
    end)
    |> order_by([p], asc: p.name)
    |> Repo.all()
    |> Ash.load!([:organization])
  end

  @spec get_project!(integer() | String.t()) :: Project.t()
  def get_project!(id) do
    Project
    |> Ash.get!(id)
    |> Ash.load!([:organization, :project_roles])
  end

  @spec create_project(map(), keyword()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_project(attrs \\ %{}, opts \\ []) do
    execute_ash_action(Project, :create, attrs, opts, Project.changeset(%Project{}, attrs))
  end

  @spec update_project(Project.t(), map(), keyword()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_project(%Project{} = project, attrs, opts \\ []) do
    execute_ash_action(project, :update, attrs, opts, Project.changeset(project, attrs))
  end

  @spec delete_project(Project.t(), keyword()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | atom()}
  def delete_project(%Project{} = project, opts \\ []) do
    execute_ash_action(project, :destroy, %{}, opts, Project.changeset(project, %{}))
  end

  @spec change_project(Project.t()) :: Ecto.Changeset.t()
  def change_project(%Project{} = project \\ %Project{}) do
    Project.changeset(project, %{})
  end

  @spec suggest_projects(String.t(), pos_integer()) :: [%{id: integer(), name: String.t()}]
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

  @spec list_project_roles(integer() | String.t()) :: [ProjectRole.t()]
  def list_project_roles(project_id) do
    ProjectRole
    |> where([pr], pr.project_id == ^project_id)
    |> Repo.all()
    |> Ash.load!([:person])
  end

  @spec list_project_roles_for_person(integer() | String.t()) :: [ProjectRole.t()]
  def list_project_roles_for_person(person_id) do
    ProjectRole
    |> where([pr], pr.person_id == ^person_id)
    |> Repo.all()
    |> Ash.load!([:project])
  end

  @spec get_project_role!(integer() | String.t()) :: ProjectRole.t()
  def get_project_role!(id), do: ProjectRole |> Ash.get!(id) |> Ash.load!([:project, :person])

  @spec create_project_role(map(), keyword()) ::
          {:ok, ProjectRole.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_project_role(attrs \\ %{}, opts \\ []) do
    result =
      execute_ash_action(
        ProjectRole,
        :create,
        attrs,
        opts,
        ProjectRole.changeset(%ProjectRole{}, attrs)
      )

    case result do
      {:ok, pr} -> {:ok, Ash.load!(pr, [:project, :person])}
      error -> error
    end
  end

  @spec delete_project_role(ProjectRole.t(), keyword()) ::
          {:ok, ProjectRole.t()} | {:error, Ecto.Changeset.t() | atom()}
  def delete_project_role(%ProjectRole{} = pr, opts \\ []) do
    execute_ash_action(pr, :destroy, %{}, opts, ProjectRole.changeset(pr, %{}))
  end

  @spec change_project_role(ProjectRole.t()) :: Ecto.Changeset.t()
  def change_project_role(%ProjectRole{} = pr \\ %ProjectRole{}) do
    ProjectRole.changeset(pr, %{})
  end

  # ── Project Repositories ─────────────────────────────────────────────────────

  @spec list_project_repositories(integer() | String.t()) :: [ProjectRepository.t()]
  def list_project_repositories(project_id) do
    ProjectRepository
    |> where([r], r.project_id == ^project_id)
    |> order_by([r], asc: r.kind, asc: r.id)
    |> Repo.all()
  end

  @spec get_project_repository!(integer() | String.t()) :: ProjectRepository.t()
  def get_project_repository!(id), do: Repo.get!(ProjectRepository, id)

  @spec create_project_repository(map(), keyword()) ::
          {:ok, ProjectRepository.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_project_repository(attrs \\ %{}, opts \\ []) do
    execute_ash_action(
      ProjectRepository,
      :create,
      attrs,
      opts,
      ProjectRepository.changeset(%ProjectRepository{}, attrs)
    )
  end

  @spec update_project_repository(ProjectRepository.t(), map(), keyword()) ::
          {:ok, ProjectRepository.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_project_repository(%ProjectRepository{} = repo, attrs, opts \\ []) do
    execute_ash_action(repo, :update, attrs, opts, ProjectRepository.changeset(repo, attrs))
  end

  @spec delete_project_repository(ProjectRepository.t(), keyword()) ::
          {:ok, ProjectRepository.t()} | {:error, Ecto.Changeset.t() | atom()}
  def delete_project_repository(%ProjectRepository{} = repo, opts \\ []) do
    execute_ash_action(repo, :destroy, %{}, opts, ProjectRepository.changeset(repo, %{}))
  end

  @spec change_project_repository(ProjectRepository.t()) :: Ecto.Changeset.t()
  def change_project_repository(%ProjectRepository{} = repo \\ %ProjectRepository{}) do
    ProjectRepository.changeset(repo, %{})
  end

  # ── Dashboard / Ownership counts ─────────────────────────────────────────────

  @spec count_domains_without_project() :: non_neg_integer()
  def count_domains_without_project do
    Repo.aggregate(from(d in Ravner.Domains.Domain, where: is_nil(d.project_id)), :count, :id)
  end

  @spec count_projects_without_roles() :: non_neg_integer()
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

  @spec count_people_without_org() :: non_neg_integer()
  def count_people_without_org do
    Repo.aggregate(from(p in Person, where: is_nil(p.organization_id)), :count, :id)
  end

  # ── Internal Helpers ─────────────────────────────────────────────────────────

  defp execute_ash_action(resource_or_record, action_type, attrs, opts, fallback_changeset) do
    actor = Keyword.get(opts, :actor)

    if fallback_changeset.valid? do
      result =
        case action_type do
          :create ->
            resource_or_record
            |> Ash.Changeset.for_create(:create, attrs, actor: actor)
            |> Ash.create()

          :update ->
            resource_or_record
            |> Ash.Changeset.for_update(:update, attrs, actor: actor)
            |> Ash.update()

          :destroy ->
            Ash.destroy(resource_or_record, actor: actor)
        end

      case result do
        :ok ->
          {:ok, resource_or_record}

        {:ok, record} ->
          {:ok, record}

        {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Forbidden{} | _]}} ->
          {:error, :forbidden}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error, :forbidden}

        {:error, ash_err} ->
          Logger.warning(
            "Ravner.Inventory: Ash #{action_type} action failed, falling back to changeset: " <>
              inspect(ash_err, limit: :infinity, printable_limit: 4096)
          )

          {:error, fallback_changeset}
      end
    else
      {:error, fallback_changeset}
    end
  end
end
