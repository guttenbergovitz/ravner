defmodule Ravner.Inventory do
  @moduledoc """
  Enterprise infrastructure governance context.

  Manages the corporate asset ownership hierarchy:
  `Brand` -> `Organization` -> `Project` -> `Person` -> `ProjectRole`.

  ## Architecture & Facade Pattern

  This module serves as a stable facade for enterprise governance:
  - **Mutations (`create_*`, `update_*`, `delete_*`)**:
    Delegated directly to Ash Framework resources (`Ravner.Inventory.*`).
    Each mutation evaluates declarative authorization policies (`Ash.Policy.Authorizer`)
    using the provided `:actor` option (e.g. `opts[:actor]`).
  - **Queries (`list_*`, `get_*!`)**:
    Optimized queries and Ash loaders returning strongly-typed governance structs
    for Phoenix LiveView administrative dashboards.
  """

  require Logger
  require Ash.Query

  import Ecto.Query, warn: false
  alias Ravner.Repo

  alias Ravner.Inventory.Brand
  alias Ravner.Inventory.Organization
  alias Ravner.Inventory.Person
  alias Ravner.Inventory.Project
  alias Ravner.Inventory.ProjectRepository
  alias Ravner.Inventory.ProjectRole
  alias Ravner.Inventory.Application
  alias Ravner.Inventory.ValueStream
  alias Ravner.Inventory.BusinessCapability
  alias Ravner.Inventory.Datastore
  alias Ravner.Inventory.HostingEnvironment
  alias Ravner.Inventory.Registrar
  alias Ravner.Inventory.NetworkAccess
  alias Ravner.Inventory.ExternalService
  alias Ravner.Inventory.ArchitectureConstraint
  alias Ravner.Inventory.ApplicationValueStream
  alias Ravner.Inventory.ApplicationCapability
  alias Ravner.Inventory.ApplicationExternalService

  # ── Brands ───────────────────────────────────────────────────────────────────

  @doc """
  Lists all brands registered in the enterprise inventory.
  Optional `:scope` filters brands to the authorized ones if non-global.
  """
  @spec list_brands(keyword()) :: [Brand.t()]
  def list_brands(opts \\ []) do
    scope = Keyword.get(opts, :scope)

    Brand
    |> Ash.Query.sort(name: :asc)
    |> then(fn q ->
      if scope && not scope.global? do
        Ash.Query.filter(q, id in ^scope.brand_ids)
      else
        q
      end
    end)
    |> Ash.read!(authorize?: false)
    |> Ash.load!([:brand_manager], authorize?: false)
  end

  @doc """
  Gets a single brand by ID. Raises Ecto.NoResultsError if not found.
  """
  @spec get_brand!(integer() | String.t()) :: Brand.t()
  def get_brand!(id) do
    Brand
    |> Ash.get!(id, authorize?: false)
    |> Ash.load!([:brand_manager], authorize?: false)
  end

  @doc """
  Creates a new Brand resource through Ash governance actions.
  """
  @spec create_brand(map(), keyword()) :: {:ok, Brand.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_brand(attrs \\ %{}, opts \\ []) do
    execute_ash_action(Brand, :create, attrs, opts, Brand.changeset(%Brand{}, attrs))
  end

  @doc """
  Updates an existing Brand resource through Ash governance actions.
  """
  @spec update_brand(Brand.t(), map(), keyword()) ::
          {:ok, Brand.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_brand(%Brand{} = brand, attrs, opts \\ []) do
    execute_ash_action(brand, :update, attrs, opts, Brand.changeset(brand, attrs))
  end

  @doc """
  Assigns a Brand Manager to an existing Brand resource through Ash governance action.
  """
  @spec assign_brand_manager(Brand.t(), integer() | nil, keyword()) ::
          {:ok, Brand.t()} | {:error, Ecto.Changeset.t() | atom()}
  def assign_brand_manager(%Brand{} = brand, manager_id, opts \\ []) do
    execute_ash_action(
      brand,
      :assign_brand_manager,
      %{brand_manager_id: manager_id},
      opts,
      Brand.changeset(brand, %{brand_manager_id: manager_id})
    )
  end

  @doc """
  Destroys a Brand resource through Ash governance actions.
  """
  @spec delete_brand(Brand.t(), keyword()) ::
          {:ok, Brand.t()} | {:error, Ecto.Changeset.t() | atom()}
  def delete_brand(%Brand{} = brand, opts \\ []) do
    execute_ash_action(brand, :destroy, %{}, opts, Brand.changeset(brand, %{}))
  end

  @doc """
  Returns a changeset for tracking Brand changes in UI forms.
  """
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

  @inventory_action_atoms [:create, :update, :destroy, :assign_brand_manager, :assign_manager]

  @doc """
  Lists all audit trail / paper trail versions for a brand, ordered from newest to oldest.
  """
  @spec list_brand_versions(Brand.t() | integer() | String.t()) :: [map()]
  def list_brand_versions(%Brand{id: id}), do: list_brand_versions(id)
  def list_brand_versions(id) when is_binary(id), do: list_brand_versions(String.to_integer(id))

  def list_brand_versions(id) when is_integer(id) do
    _ = @inventory_action_atoms

    Brand.Version
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  # ── Organizations ────────────────────────────────────────────────────────────

  @spec list_organizations(keyword()) :: [Organization.t()]
  def list_organizations(opts \\ []) do
    scope = Keyword.get(opts, :scope)

    Organization
    |> Ash.Query.sort(name: :asc)
    |> then(fn q ->
      if scope && not scope.global? do
        Ash.Query.filter(q, id in ^scope.organization_ids)
      else
        q
      end
    end)
    |> Ash.read!(authorize?: false)
    |> Ash.load!([:brand, :manager], authorize?: false)
  end

  @spec get_organization!(integer() | String.t()) :: Organization.t()
  def get_organization!(id),
    do:
      Organization
      |> Ash.get!(id, authorize?: false)
      |> Ash.load!([:manager, brand: [:brand_manager]], authorize?: false)

  @doc """
  Assigns an Organization Manager to an existing Organization resource through Ash governance action.
  """
  @spec assign_organization_manager(Organization.t(), integer() | nil, keyword()) ::
          {:ok, Organization.t()} | {:error, Ecto.Changeset.t() | atom()}
  def assign_organization_manager(%Organization{} = org, manager_id, opts \\ []) do
    execute_ash_action(
      org,
      :assign_manager,
      %{manager_id: manager_id},
      opts,
      Organization.changeset(org, %{manager_id: manager_id})
    )
  end

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

  @doc """
  Lists all audit trail / paper trail versions for an organization, ordered from newest to oldest.
  """
  @spec list_organization_versions(Organization.t() | integer() | String.t()) :: [map()]
  def list_organization_versions(%Organization{id: id}), do: list_organization_versions(id)

  def list_organization_versions(id) when is_binary(id),
    do: list_organization_versions(String.to_integer(id))

  def list_organization_versions(id) when is_integer(id) do
    _ = @inventory_action_atoms

    Organization.Version
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  # ── People ───────────────────────────────────────────────────────────────────

  @spec list_people(keyword()) :: [Person.t()]
  def list_people(opts \\ []) do
    org_id = Keyword.get(opts, :organization_id)
    scope = Keyword.get(opts, :scope)

    Person
    |> then(fn q ->
      if org_id, do: where(q, [p], p.organization_id == ^org_id), else: q
    end)
    |> then(fn q ->
      if scope && not scope.global? do
        where(
          q,
          [p],
          p.organization_id in ^scope.organization_ids or
            fragment(
              "? IN (SELECT pr.person_id FROM project_roles pr WHERE pr.project_id = ANY(?))",
              p.id,
              ^scope.project_ids
            ) or
            fragment(
              "? IN (SELECT prj.project_manager_id FROM projects prj WHERE prj.id = ANY(?))",
              p.id,
              ^scope.project_ids
            ) or
            fragment(
              "? IN (SELECT prj.product_owner_id FROM projects prj WHERE prj.id = ANY(?))",
              p.id,
              ^scope.project_ids
            )
        )
      else
        q
      end
    end)
    |> order_by([p], asc: p.last_name, asc: p.first_name)
    |> Repo.all()
    |> then(fn people ->
      actor = Keyword.get(opts, :actor)

      if actor do
        try do
          Ash.load!(people, [:organization, :user], actor: actor)
        rescue
          _ -> Ash.load!(people, [:organization], authorize?: false)
        end
      else
        Ash.load!(people, [:organization], authorize?: false)
      end
    end)
  end

  @spec get_person!(integer() | String.t()) :: Person.t()
  def get_person!(id),
    do:
      Person
      |> Ash.get!(id, authorize?: false)
      |> Ash.load!([:project_roles, organization: [:brand]], authorize?: false)

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

  @doc """
  Lists all audit trail / paper trail versions for a person, ordered from newest to oldest.
  """
  @spec list_person_versions(Person.t() | integer() | String.t()) :: [map()]
  def list_person_versions(%Person{id: id}), do: list_person_versions(id)

  def list_person_versions(id) when is_binary(id),
    do: list_person_versions(String.to_integer(id))

  def list_person_versions(id) when is_integer(id) do
    _ = @inventory_action_atoms

    Person.Version
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  # ── Projects ─────────────────────────────────────────────────────────────────

  @spec list_projects(keyword()) :: [Project.t()]
  def list_projects(opts \\ []) do
    org_id = Keyword.get(opts, :organization_id)
    scope = Keyword.get(opts, :scope)

    Project
    |> then(fn q ->
      if org_id, do: where(q, [p], p.organization_id == ^org_id), else: q
    end)
    |> then(fn q ->
      if scope && not scope.global? do
        where(q, [p], p.id in ^scope.project_ids)
      else
        q
      end
    end)
    |> order_by([p], asc: p.name)
    |> Repo.all()
    |> Ash.load!([:organization, :project_manager, :product_owner], authorize?: false)
  end

  @spec get_project(integer() | String.t(), keyword()) ::
          {:ok, Project.t()} | {:error, term()}
  def get_project(id, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    auth_opts = if is_nil(actor), do: [authorize?: false], else: [actor: actor]

    with {:ok, project} <- Ash.get(Project, id, auth_opts),
         {:ok, project} <-
           Ash.load(
             project,
             [
               :project_roles,
               :project_manager,
               :product_owner,
               organization: [:brand],
               applications: [
                 :hosting_environment,
                 :network_access,
                 :datastores,
                 :domains,
                 :repositories,
                 :value_streams,
                 :capabilities,
                 :external_services,
                 :constraints
               ]
             ],
             auth_opts
           ) do
      {:ok, project}
    end
  end

  @spec get_project!(integer() | String.t(), keyword()) :: Project.t()
  def get_project!(id, opts \\ []) do
    case get_project(id, opts) do
      {:ok, project} -> project
      {:error, error} -> raise error
    end
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

  @doc """
  Lists all audit trail / paper trail versions for a project, ordered from newest to oldest.
  """
  @spec list_project_versions(Project.t() | integer() | String.t()) :: [map()]
  def list_project_versions(%Project{id: id}), do: list_project_versions(id)

  def list_project_versions(id) when is_binary(id),
    do: list_project_versions(String.to_integer(id))

  def list_project_versions(id) when is_integer(id) do
    _ = @inventory_action_atoms

    Project.Version
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  # ── Project Roles ────────────────────────────────────────────────────────────

  @spec list_project_roles(integer() | String.t()) :: [ProjectRole.t()]
  def list_project_roles(project_id) do
    ProjectRole
    |> where([pr], pr.project_id == ^project_id)
    |> Repo.all()
    |> Ash.load!([:person], authorize?: false)
  end

  @spec list_project_roles_for_person(integer() | String.t()) :: [ProjectRole.t()]
  def list_project_roles_for_person(person_id) do
    ProjectRole
    |> where([pr], pr.person_id == ^person_id)
    |> Repo.all()
    |> Ash.load!([:project], authorize?: false)
  end

  @spec get_project_role!(integer() | String.t()) :: ProjectRole.t()
  def get_project_role!(id),
    do:
      ProjectRole
      |> Ash.get!(id, authorize?: false)
      |> Ash.load!([:project, :person], authorize?: false)

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
      {:ok, pr} ->
        actor = Keyword.get(opts, :actor)
        load_opts = if is_nil(actor), do: [authorize?: false], else: [actor: actor]
        {:ok, Ash.load!(pr, [:project, :person], load_opts)}

      error ->
        error
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

  @doc """
  Lists all audit trail / paper trail versions for a project role, ordered from newest to oldest.
  """
  @spec list_project_role_versions(ProjectRole.t() | integer() | String.t()) :: [map()]
  def list_project_role_versions(%ProjectRole{id: id}), do: list_project_role_versions(id)

  def list_project_role_versions(id) when is_binary(id),
    do: list_project_role_versions(String.to_integer(id))

  def list_project_role_versions(id) when is_integer(id) do
    _ = @inventory_action_atoms

    ProjectRole.Version
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  # ── Project Repositories ─────────────────────────────────────────────────────

  @spec list_project_repositories(integer() | String.t()) :: [ProjectRepository.t()]
  def list_project_repositories(project_id) do
    domain_ids_query =
      from(d in Ravner.Domains.Domain, where: d.project_id == ^project_id, select: d.id)

    ProjectRepository
    |> where([r], r.project_id == ^project_id or r.domain_id in subquery(domain_ids_query))
    |> order_by([r], asc: r.kind, asc: r.id)
    |> Repo.all()
    |> Ash.load!([:domain], authorize?: false)
  end

  @doc """
  Lists all repositories across the inventory, preloaded with project and domain.
  """
  @spec list_all_repositories(keyword()) :: [ProjectRepository.t()]
  def list_all_repositories(_opts \\ []) do
    ProjectRepository
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> Repo.all()
    |> Ash.load!([:project, :domain], authorize?: false)
  end

  @doc """
  Returns summary statistics for repositories across the inventory.
  """
  @spec repository_stats() :: %{
          total: non_neg_integer(),
          vulnerable: non_neg_integer(),
          cve_count: non_neg_integer(),
          critical_count: non_neg_integer(),
          high_count: non_neg_integer(),
          providers: %{optional(String.t()) => non_neg_integer()}
        }
  def repository_stats do
    repos = Repo.all(ProjectRepository)

    vulnerable_repos = Enum.filter(repos, &((&1.vulnerability_count || 0) > 0))
    total_cves = Enum.sum(Enum.map(repos, &(&1.vulnerability_count || 0)))
    critical_cves = Enum.sum(Enum.map(repos, &(&1.critical_vuln_count || 0)))
    high_cves = Enum.sum(Enum.map(repos, &(&1.high_vuln_count || 0)))

    providers =
      repos
      |> Enum.map(&(&1.provider || "other"))
      |> Enum.frequencies()

    total_secrets = Enum.sum(Enum.map(repos, &(&1.secrets_count || 0)))
    leaking_repos = Enum.filter(repos, &((&1.secrets_count || 0) > 0))

    %{
      total: length(repos),
      vulnerable: length(vulnerable_repos),
      cve_count: total_cves,
      critical_count: critical_cves,
      high_count: high_cves,
      secrets_count: total_secrets,
      leaking_repos_count: length(leaking_repos),
      providers: providers
    }
  end

  @doc """
  Lists repositories attached directly to a domain.
  """
  @spec list_domain_repositories(integer() | String.t()) :: [ProjectRepository.t()]
  def list_domain_repositories(domain_id) do
    ProjectRepository
    |> where([r], r.domain_id == ^domain_id)
    |> order_by([r], desc: r.is_primary, asc: r.kind, asc: r.id)
    |> Repo.all()
  end

  @doc """
  Lists all repositories accessible or linked to a domain.
  Includes direct domain repositories and shared repositories from the assigned project.
  Deduplicates by URL, preferring domain-attached repos over project-inherited ones.
  """
  @spec list_all_repositories_for_domain(map()) :: [ProjectRepository.t()]
  def list_all_repositories_for_domain(%{id: domain_id} = domain) do
    query =
      if domain.project_id do
        ProjectRepository
        |> where(
          [r],
          r.domain_id == ^domain_id or
            (r.project_id == ^domain.project_id and is_nil(r.domain_id))
        )
      else
        ProjectRepository
        |> where([r], r.domain_id == ^domain_id)
      end

    query
    |> order_by([r],
      desc: r.domain_id == ^domain_id and r.is_primary,
      desc: r.domain_id == ^domain_id,
      asc: r.kind,
      asc: r.id
    )
    |> Repo.all()
    # ponytail: dedupe by URL, keep first (domain-attached takes priority due to ordering)
    |> Enum.uniq_by(& &1.url)
  end

  def list_all_repositories_for_domain(_), do: []

  @doc """
  Resolves the primary repository for a domain.
  1. Direct domain repo marked with is_primary == true.
  2. Any direct domain repo (first created).
  3. Shared project repo marked with is_primary == true.
  4. Any shared project repo.
  """
  @spec get_primary_repository_for_domain(map()) :: ProjectRepository.t() | nil
  def get_primary_repository_for_domain(%{id: domain_id} = domain) do
    direct_primary =
      ProjectRepository
      |> where([r], r.domain_id == ^domain_id and r.is_primary == true)
      |> limit(1)
      |> Repo.one()

    cond do
      direct_primary ->
        direct_primary

      true ->
        direct_any =
          ProjectRepository
          |> where([r], r.domain_id == ^domain_id)
          |> order_by([r], asc: r.id)
          |> limit(1)
          |> Repo.one()

        cond do
          direct_any ->
            direct_any

          domain.project_id ->
            project_primary =
              ProjectRepository
              |> where(
                [r],
                r.project_id == ^domain.project_id and is_nil(r.domain_id) and
                  r.is_primary == true
              )
              |> limit(1)
              |> Repo.one()

            if project_primary do
              project_primary
            else
              ProjectRepository
              |> where([r], r.project_id == ^domain.project_id and is_nil(r.domain_id))
              |> order_by([r], asc: r.id)
              |> limit(1)
              |> Repo.one()
            end

          true ->
            nil
        end
    end
  end

  def get_primary_repository_for_domain(_), do: nil

  @doc """
  Designates a repository as primary for a domain, updating other direct repositories to secondary.
  """
  @spec set_primary_repository_for_domain(integer() | String.t(), integer(), map()) ::
          {:ok, ProjectRepository.t()} | {:error, term()}
  def set_primary_repository_for_domain(repo_id, domain_id, actor) do
    # 1. Reset is_primary on other repositories for this domain
    ProjectRepository
    |> where([r], r.domain_id == ^domain_id and r.id != ^repo_id)
    |> Repo.update_all(set: [is_primary: false])

    # 2. Set is_primary on target repo and ensure domain_id is set
    target = get_project_repository!(repo_id)

    with {:ok, updated} <-
           update_project_repository(target, %{is_primary: true, domain_id: domain_id},
             actor: actor
           ),
         domain <- Ravner.Domains.get_domain!(domain_id),
         {:ok, _} <-
           Ravner.Domains.update_domain(domain, %{repository_url: updated.url}, actor: actor) do
      {:ok, updated}
    end
  end

  @spec get_project_repository!(integer() | String.t()) :: ProjectRepository.t()
  def get_project_repository!(id), do: Repo.get!(ProjectRepository, id)

  @doc """
  Runs dependency vulnerability scanning on a project repository.
  """
  @spec scan_project_repository(ProjectRepository.t() | integer(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def scan_project_repository(repo_or_id, opts \\ []) do
    Ravner.Scans.RepoScanner.scan_repository(repo_or_id, opts)
  end

  @doc """
  Lists vulnerabilities discovered in a repository.
  """
  @spec list_repository_vulnerabilities(integer()) ::
          [Ravner.Scans.ProjectRepositoryVulnerability.t()]
  def list_repository_vulnerabilities(repo_id) do
    Ravner.SecurityScans.list_repository_vulnerabilities(repo_id)
  end

  @doc """
  Lists secrets discovered in a repository.
  """
  @spec list_repository_secrets(integer(), keyword()) ::
          [Ravner.Scans.ProjectRepositorySecret.t()]
  def list_repository_secrets(repo_id, opts \\ []) do
    Ravner.Scans.SecretsScanner.list_repository_secrets(repo_id, opts)
  end

  @doc """
  Lists secrets discovered across all repositories in a project.
  """
  @spec list_project_secrets(integer() | String.t(), keyword()) ::
          [Ravner.Scans.ProjectRepositorySecret.t()]
  def list_project_secrets(project_id, opts \\ []) do
    Ravner.Scans.SecretsScanner.list_project_secrets(project_id, opts)
  end

  @doc """
  Updates the lifecycle status of a discovered secret ("active", "resolved", "false_positive").
  """
  @spec mark_secret_status(integer(), String.t()) ::
          {:ok, Ravner.Scans.ProjectRepositorySecret.t()} | {:error, term()}
  def mark_secret_status(secret_id, status) do
    Ravner.Scans.SecretsScanner.mark_secret_status(secret_id, status)
  end

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

  # ── Applications ─────────────────────────────────────────────────────────────

  @doc "Lists all applications registered in the digital landscape inventory."
  @spec list_applications(keyword()) :: [Application.t()]
  def list_applications(opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    app_type = Keyword.get(opts, :app_type)

    Application
    |> Ash.Query.sort(name: :asc)
    |> then(fn q ->
      if project_id, do: Ash.Query.filter(q, project_id == ^project_id), else: q
    end)
    |> then(fn q ->
      if app_type, do: Ash.Query.filter(q, app_type == ^to_string(app_type)), else: q
    end)
    |> Ash.read!(authorize?: false)
    |> Ash.load!(
      [
        :project,
        :hosting_environment,
        :network_access,
        :datastores,
        :domains,
        :repositories
      ],
      authorize?: false
    )
  end

  @doc "Gets a single application by ID."
  @spec get_application!(integer() | String.t()) :: Application.t()
  def get_application!(id) do
    Application
    |> Ash.get!(id, authorize?: false)
    |> Ash.load!(
      [
        :project,
        :hosting_environment,
        :network_access,
        :datastores,
        :domains,
        :repositories,
        :value_streams,
        :capabilities,
        :external_services,
        :constraints
      ],
      authorize?: false
    )
  end

  @doc "Creates a new Application resource through Ash governance actions."
  @spec create_application(map(), keyword()) ::
          {:ok, Application.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_application(attrs \\ %{}, opts \\ []) do
    execute_ash_action(
      Application,
      :create,
      attrs,
      opts,
      Application.changeset(%Application{}, attrs)
    )
  end

  @doc "Updates an existing Application resource through Ash governance actions."
  @spec update_application(Application.t(), map(), keyword()) ::
          {:ok, Application.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_application(%Application{} = app, attrs, opts \\ []) do
    execute_ash_action(app, :update, attrs, opts, Application.changeset(app, attrs))
  end

  @doc "Destroys an Application resource through Ash governance actions."
  @spec delete_application(Application.t(), keyword()) :: :ok | {:error, atom()}
  def delete_application(%Application{} = app, opts \\ []) do
    execute_ash_action(app, :destroy, %{}, opts, Application.changeset(app, %{}))
  end

  # ── Value Streams ────────────────────────────────────────────────────────────

  @doc "Lists all value streams."
  @spec list_value_streams(keyword()) :: [ValueStream.t()]
  def list_value_streams(opts \\ []) do
    brand_id = Keyword.get(opts, :brand_id)

    ValueStream
    |> Ash.Query.sort(name: :asc)
    |> then(fn q -> if brand_id, do: Ash.Query.filter(q, brand_id == ^brand_id), else: q end)
    |> Ash.read!(authorize?: false)
    |> Ash.load!([:brand, :business_owner, :applications], authorize?: false)
  end

  @doc "Gets a single value stream by ID."
  @spec get_value_stream!(integer() | String.t()) :: ValueStream.t()
  def get_value_stream!(id) do
    ValueStream
    |> Ash.get!(id, authorize?: false)
    |> Ash.load!([:brand, :business_owner, :applications], authorize?: false)
  end

  @doc "Creates a new ValueStream resource."
  @spec create_value_stream(map(), keyword()) ::
          {:ok, ValueStream.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_value_stream(attrs \\ %{}, opts \\ []) do
    execute_ash_action(
      ValueStream,
      :create,
      attrs,
      opts,
      ValueStream.changeset(%ValueStream{}, attrs)
    )
  end

  @doc "Updates an existing ValueStream resource."
  @spec update_value_stream(ValueStream.t(), map(), keyword()) ::
          {:ok, ValueStream.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_value_stream(%ValueStream{} = stream, attrs, opts \\ []) do
    execute_ash_action(stream, :update, attrs, opts, ValueStream.changeset(stream, attrs))
  end

  @doc "Destroys a ValueStream resource."
  @spec delete_value_stream(ValueStream.t(), keyword()) :: :ok | {:error, atom()}
  def delete_value_stream(%ValueStream{} = stream, opts \\ []) do
    execute_ash_action(stream, :destroy, %{}, opts, ValueStream.changeset(stream, %{}))
  end

  # ── Business Capabilities ────────────────────────────────────────────────────

  @doc "Lists all business capabilities."
  @spec list_business_capabilities(keyword()) :: [BusinessCapability.t()]
  def list_business_capabilities(_opts \\ []) do
    BusinessCapability
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
    |> Ash.load!([:applications], authorize?: false)
  end

  @doc "Gets a single business capability by ID."
  @spec get_business_capability!(integer() | String.t()) :: BusinessCapability.t()
  def get_business_capability!(id) do
    BusinessCapability
    |> Ash.get!(id, authorize?: false)
    |> Ash.load!([:applications], authorize?: false)
  end

  @doc "Creates a new BusinessCapability resource."
  @spec create_business_capability(map(), keyword()) ::
          {:ok, BusinessCapability.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_business_capability(attrs \\ %{}, opts \\ []) do
    execute_ash_action(
      BusinessCapability,
      :create,
      attrs,
      opts,
      BusinessCapability.changeset(%BusinessCapability{}, attrs)
    )
  end

  @doc "Updates an existing BusinessCapability resource."
  @spec update_business_capability(BusinessCapability.t(), map(), keyword()) ::
          {:ok, BusinessCapability.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_business_capability(%BusinessCapability{} = cap, attrs, opts \\ []) do
    execute_ash_action(cap, :update, attrs, opts, BusinessCapability.changeset(cap, attrs))
  end

  @doc "Destroys a BusinessCapability resource."
  @spec delete_business_capability(BusinessCapability.t(), keyword()) :: :ok | {:error, atom()}
  def delete_business_capability(%BusinessCapability{} = cap, opts \\ []) do
    execute_ash_action(cap, :destroy, %{}, opts, BusinessCapability.changeset(cap, %{}))
  end

  # ── Datastores ───────────────────────────────────────────────────────────────

  @doc "Lists all datastores."
  @spec list_datastores(keyword()) :: [Datastore.t()]
  def list_datastores(opts \\ []) do
    application_id = Keyword.get(opts, :application_id)

    Datastore
    |> Ash.Query.sort(name: :asc)
    |> then(fn q ->
      if application_id, do: Ash.Query.filter(q, application_id == ^application_id), else: q
    end)
    |> Ash.read!(authorize?: false)
    |> Ash.load!([:application, :hosting_environment], authorize?: false)
  end

  @doc "Gets a single datastore by ID."
  @spec get_datastore!(integer() | String.t()) :: Datastore.t()
  def get_datastore!(id) do
    Datastore
    |> Ash.get!(id, authorize?: false)
    |> Ash.load!([:application, :hosting_environment], authorize?: false)
  end

  @doc "Creates a new Datastore resource."
  @spec create_datastore(map(), keyword()) ::
          {:ok, Datastore.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_datastore(attrs \\ %{}, opts \\ []) do
    execute_ash_action(Datastore, :create, attrs, opts, Datastore.changeset(%Datastore{}, attrs))
  end

  @doc "Updates an existing Datastore resource."
  @spec update_datastore(Datastore.t(), map(), keyword()) ::
          {:ok, Datastore.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_datastore(%Datastore{} = datastore, attrs, opts \\ []) do
    execute_ash_action(datastore, :update, attrs, opts, Datastore.changeset(datastore, attrs))
  end

  @doc "Deletes a Datastore resource."
  @spec delete_datastore(Datastore.t(), keyword()) ::
          {:ok, Datastore.t()} | {:error, Ecto.Changeset.t() | atom()}
  def delete_datastore(%Datastore{} = datastore, opts \\ []) do
    execute_ash_action(datastore, :destroy, %{}, opts, Datastore.changeset(datastore, %{}))
  end

  # ── Hosting Environments & Registrars ────────────────────────────────────────

  @doc "Lists all hosting environments."
  @spec list_hosting_environments(keyword()) :: [HostingEnvironment.t()]
  def list_hosting_environments(_opts \\ []) do
    HostingEnvironment
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
  end

  @doc "Gets a single hosting environment by ID."
  @spec get_hosting_environment!(integer() | String.t()) :: HostingEnvironment.t()
  def get_hosting_environment!(id) do
    HostingEnvironment
    |> Ash.get!(id, authorize?: false)
  end

  @doc "Creates a new HostingEnvironment resource."
  @spec create_hosting_environment(map(), keyword()) ::
          {:ok, HostingEnvironment.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_hosting_environment(attrs \\ %{}, opts \\ []) do
    execute_ash_action(
      HostingEnvironment,
      :create,
      attrs,
      opts,
      HostingEnvironment.changeset(%HostingEnvironment{}, attrs)
    )
  end

  @doc "Lists all registrars."
  @spec list_registrars(keyword()) :: [Registrar.t()]
  def list_registrars(_opts \\ []) do
    Registrar
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
  end

  @doc "Gets a single registrar by ID."
  @spec get_registrar!(integer() | String.t()) :: Registrar.t()
  def get_registrar!(id) do
    Registrar
    |> Ash.get!(id, authorize?: false)
  end

  @doc "Creates a new Registrar resource."
  @spec create_registrar(map(), keyword()) ::
          {:ok, Registrar.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_registrar(attrs \\ %{}, opts \\ []) do
    execute_ash_action(Registrar, :create, attrs, opts, Registrar.changeset(%Registrar{}, attrs))
  end

  @doc "Lists all network access boundaries."
  @spec list_network_accesses(keyword()) :: [NetworkAccess.t()]
  def list_network_accesses(_opts \\ []) do
    NetworkAccess
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
  end

  @doc "Creates a new NetworkAccess resource."
  @spec create_network_access(map(), keyword()) ::
          {:ok, NetworkAccess.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_network_access(attrs \\ %{}, opts \\ []) do
    execute_ash_action(
      NetworkAccess,
      :create,
      attrs,
      opts,
      NetworkAccess.changeset(%NetworkAccess{}, attrs)
    )
  end

  @doc "Lists all external services."
  @spec list_external_services(keyword()) :: [ExternalService.t()]
  def list_external_services(_opts \\ []) do
    ExternalService
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
  end

  @doc "Creates a new ExternalService resource."
  @spec create_external_service(map(), keyword()) ::
          {:ok, ExternalService.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_external_service(attrs \\ %{}, opts \\ []) do
    execute_ash_action(
      ExternalService,
      :create,
      attrs,
      opts,
      ExternalService.changeset(%ExternalService{}, attrs)
    )
  end

  # ── Architecture Constraints (Policy-as-Code) ────────────────────────────────

  @doc "Lists all architecture constraints."
  @spec list_architecture_constraints(keyword()) :: [ArchitectureConstraint.t()]
  def list_architecture_constraints(opts \\ []) do
    application_id = Keyword.get(opts, :application_id)

    ArchitectureConstraint
    |> Ash.Query.sort(name: :asc)
    |> then(fn q ->
      if application_id, do: Ash.Query.filter(q, application_id == ^application_id), else: q
    end)
    |> Ash.read!(authorize?: false)
    |> Ash.load!([:application], authorize?: false)
  end

  @doc "Creates a new ArchitectureConstraint resource."
  @spec create_architecture_constraint(map(), keyword()) ::
          {:ok, ArchitectureConstraint.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_architecture_constraint(attrs \\ %{}, opts \\ []) do
    execute_ash_action(
      ArchitectureConstraint,
      :create,
      attrs,
      opts,
      ArchitectureConstraint.changeset(%ArchitectureConstraint{}, attrs)
    )
  end

  @doc "Gets a single architecture constraint by ID."
  @spec get_architecture_constraint!(integer() | String.t()) :: ArchitectureConstraint.t()
  def get_architecture_constraint!(id) do
    ArchitectureConstraint
    |> Ash.get!(id, authorize?: false)
    |> Ash.load!([:application], authorize?: false)
  end

  @doc "Updates an existing ArchitectureConstraint resource."
  @spec update_architecture_constraint(ArchitectureConstraint.t(), map(), keyword()) ::
          {:ok, ArchitectureConstraint.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_architecture_constraint(%ArchitectureConstraint{} = constraint, attrs, opts \\ []) do
    execute_ash_action(
      constraint,
      :update,
      attrs,
      opts,
      ArchitectureConstraint.changeset(constraint, attrs)
    )
  end

  @doc "Deletes an ArchitectureConstraint resource."
  @spec delete_architecture_constraint(ArchitectureConstraint.t(), keyword()) ::
          {:ok, ArchitectureConstraint.t()} | {:error, Ecto.Changeset.t() | atom()}
  def delete_architecture_constraint(%ArchitectureConstraint{} = constraint, opts \\ []) do
    execute_ash_action(
      constraint,
      :destroy,
      %{},
      opts,
      ArchitectureConstraint.changeset(constraint, %{})
    )
  end

  # ── Application Join Resources ───────────────────────────────────────────────

  @doc "Associates an application with a value stream."
  @spec create_application_value_stream(map(), keyword()) ::
          {:ok, ApplicationValueStream.t()} | {:error, term()}
  def create_application_value_stream(attrs, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    ApplicationValueStream
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create()
  end

  @doc "Associates an application with a business capability."
  @spec create_application_capability(map(), keyword()) ::
          {:ok, ApplicationCapability.t()} | {:error, term()}
  def create_application_capability(attrs, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    ApplicationCapability
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create()
  end

  @doc "Associates an application with an external service."
  @spec create_application_external_service(map(), keyword()) ::
          {:ok, ApplicationExternalService.t()} | {:error, term()}
  def create_application_external_service(attrs, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    ApplicationExternalService
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create()
  end

  @doc "Removes an association between an application and an external service."
  @spec delete_application_external_service(integer(), integer(), keyword()) ::
          :ok | {:error, term()}
  def delete_application_external_service(app_id, service_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    case ApplicationExternalService
         |> Ash.Query.filter(application_id == ^app_id and external_service_id == ^service_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %ApplicationExternalService{} = join} ->
        Ash.destroy(join, actor: actor)

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Removes an association between an application and a value stream."
  @spec delete_application_value_stream(integer(), integer(), keyword()) ::
          :ok | {:error, term()}
  def delete_application_value_stream(app_id, value_stream_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    case ApplicationValueStream
         |> Ash.Query.filter(application_id == ^app_id and value_stream_id == ^value_stream_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %ApplicationValueStream{} = join} ->
        Ash.destroy(join, actor: actor)

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Removes an association between an application and a business capability."
  @spec delete_application_capability(integer(), integer(), keyword()) ::
          :ok | {:error, term()}
  def delete_application_capability(app_id, capability_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    case ApplicationCapability
         |> Ash.Query.filter(
           application_id == ^app_id and business_capability_id == ^capability_id
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, %ApplicationCapability{} = join} ->
        Ash.destroy(join, actor: actor)

      _ ->
        {:error, :not_found}
    end
  end

  # ── Paper Trail Auditing for Digital Landscape ───────────────────────────────

  @doc "Lists audit trail versions for an application."
  @spec list_application_versions(Application.t() | integer() | String.t()) :: [map()]
  def list_application_versions(%Application{id: id}), do: list_application_versions(id)

  def list_application_versions(id) when is_binary(id),
    do: list_application_versions(String.to_integer(id))

  def list_application_versions(id) when is_integer(id) do
    Application.Version
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  @doc "Lists audit trail versions for a registrar."
  @spec list_registrar_versions(Registrar.t() | integer() | String.t()) :: [map()]
  def list_registrar_versions(%Registrar{id: id}), do: list_registrar_versions(id)

  def list_registrar_versions(id) when is_binary(id),
    do: list_registrar_versions(String.to_integer(id))

  def list_registrar_versions(id) when is_integer(id) do
    Registrar.Version
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  @doc "Lists audit trail versions for an architecture constraint."
  @spec list_architecture_constraint_versions(ArchitectureConstraint.t() | integer() | String.t()) ::
          [map()]
  def list_architecture_constraint_versions(%ArchitectureConstraint{id: id}),
    do: list_architecture_constraint_versions(id)

  def list_architecture_constraint_versions(id) when is_binary(id),
    do: list_architecture_constraint_versions(String.to_integer(id))

  def list_architecture_constraint_versions(id) when is_integer(id) do
    ArchitectureConstraint.Version
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
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

          action when action in [:assign_brand_manager, :assign_manager] ->
            resource_or_record
            |> Ash.Changeset.for_update(action, attrs, actor: actor)
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

          {:error, Ravner.AshErrorHelpers.to_ecto_changeset(ash_err, fallback_changeset)}
      end
    else
      {:error, fallback_changeset}
    end
  end
end
