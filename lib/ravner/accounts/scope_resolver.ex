defmodule Ravner.Accounts.ScopeResolver do
  @moduledoc """
  Functional engine resolving hierarchical resource scopes for users across
  the Client Hierarchy (Brand ➔ Company ➔ Product Owner) and the Delivery Hierarchy
  (Delivery Management ➔ Supervisor ➔ Project Manager).
  """

  import Ecto.Query

  alias Ravner.Accounts.Scope
  alias Ravner.Accounts.User
  alias Ravner.Domains.Domain
  alias Ravner.Inventory.Brand
  alias Ravner.Inventory.Organization
  alias Ravner.Inventory.Person
  alias Ravner.Inventory.Project
  alias Ravner.Inventory.ProjectRole
  alias Ravner.Repo

  @doc """
  Resolves the complete, effective resource scope for a user.
  """
  @spec resolve(User.t()) :: Scope.t()
  def resolve(%User{role: :admin} = user) do
    %Scope{
      user: user,
      person: resolve_person(user),
      role: :admin,
      admin?: true,
      editor?: true,
      viewer?: false,
      global?: true
    }
  end

  def resolve(%User{role: :editor} = user) do
    %Scope{
      user: user,
      person: resolve_person(user),
      role: :editor,
      admin?: false,
      editor?: true,
      viewer?: false,
      global?: true
    }
  end

  def resolve(%User{role: :viewer} = user) do
    %Scope{
      user: user,
      person: resolve_person(user),
      role: :viewer,
      admin?: false,
      editor?: false,
      viewer?: true,
      global?: true
    }
  end

  def resolve(%User{} = user) do
    person = resolve_person(user)
    person_id = person && person.id

    # 1. Client Hierarchy: Brand IDs
    brand_ids = resolve_brand_ids(person_id)

    # 2. Client Hierarchy: Organization IDs (under managed brands OR direct manager)
    org_ids = resolve_organization_ids(brand_ids, person_id)

    # 3. Delivery Hierarchy: Supervised PM User IDs
    supervised_pm_user_ids = resolve_supervised_pm_ids(user)

    # 4. Project IDs (from orgs + direct person roles + supervised PM roles)
    project_ids = resolve_project_ids(org_ids, person_id, supervised_pm_user_ids)

    # 5. Domain IDs (from brands + orgs + projects + direct PO/PM email assignments)
    domain_ids = resolve_domain_ids(brand_ids, org_ids, project_ids, user.email)

    %Scope{
      user: user,
      person: person,
      role: user.role,
      admin?: false,
      editor?: false,
      viewer?: false,
      global?: false,
      brand_ids: brand_ids,
      organization_ids: org_ids,
      project_ids: project_ids,
      domain_ids: domain_ids,
      supervised_pm_ids: supervised_pm_user_ids
    }
  end

  @doc """
  Ensures a `Scope` struct is present, resolving if given a `User`.
  """
  @spec ensure_scope(Scope.t() | User.t()) :: Scope.t()
  def ensure_scope(%Scope{} = scope), do: scope
  def ensure_scope(%User{} = user), do: resolve(user)

  # ── Domain Predicates ────────────────────────────────────────────────────────

  @doc """
  Determines if the actor is authorized to view a domain.
  """
  @spec can_view_domain?(Scope.t() | User.t(), integer() | String.t() | map() | nil) :: boolean()
  def can_view_domain?(_scope_or_user, nil), do: false

  def can_view_domain?(scope_or_user, domain_or_id) do
    scope = ensure_scope(scope_or_user)
    domain_id = id_of(domain_or_id)

    cond do
      scope.global? -> true
      is_nil(domain_id) -> false
      true -> domain_id in scope.domain_ids
    end
  end

  @doc """
  Determines if the actor is authorized to trigger scans on a domain.
  """
  @spec can_scan_domain?(Scope.t() | User.t(), integer() | String.t() | map() | nil) :: boolean()
  def can_scan_domain?(_scope_or_user, nil), do: false

  def can_scan_domain?(scope_or_user, domain_or_id) do
    scope = ensure_scope(scope_or_user)
    domain_id = id_of(domain_or_id)

    cond do
      scope.viewer? -> false
      scope.admin? or scope.editor? -> true
      is_nil(domain_id) -> false
      true -> domain_id in scope.domain_ids
    end
  end

  @doc """
  Determines if the actor is authorized to manage a domain (lifecycle, contacts, metadata).
  """
  @spec can_manage_domain?(Scope.t() | User.t(), integer() | String.t() | map() | nil) ::
          boolean()
  def can_manage_domain?(_scope_or_user, nil), do: false

  def can_manage_domain?(scope_or_user, domain_or_id) do
    scope = ensure_scope(scope_or_user)
    domain_id = id_of(domain_or_id)

    cond do
      scope.viewer? -> false
      scope.admin? or scope.editor? -> true
      is_nil(domain_id) -> false
      true -> domain_id in scope.domain_ids
    end
  end

  # ── Project Predicates ───────────────────────────────────────────────────────

  @doc """
  Determines if the actor is authorized to view a project.
  """
  @spec can_view_project?(Scope.t() | User.t(), integer() | String.t() | map() | nil) :: boolean()
  def can_view_project?(_scope_or_user, nil), do: false

  def can_view_project?(scope_or_user, project_or_id) do
    scope = ensure_scope(scope_or_user)
    project_id = id_of(project_or_id)

    cond do
      scope.global? -> true
      is_nil(project_id) -> false
      true -> project_id in scope.project_ids
    end
  end

  @doc """
  Determines if the actor is authorized to manage a project.
  """
  @spec can_manage_project?(Scope.t() | User.t(), integer() | String.t() | map() | nil) ::
          boolean()
  def can_manage_project?(_scope_or_user, nil), do: false

  def can_manage_project?(scope_or_user, project_or_id) do
    scope = ensure_scope(scope_or_user)
    project_id = id_of(project_or_id)

    cond do
      scope.viewer? -> false
      scope.admin? or scope.editor? -> true
      is_nil(project_id) -> false
      true -> project_id in scope.project_ids
    end
  end

  # ── Organization Predicates ──────────────────────────────────────────────────

  @doc """
  Determines if the actor is authorized to view an organization.
  """
  @spec can_view_organization?(Scope.t() | User.t(), integer() | String.t() | map() | nil) ::
          boolean()
  def can_view_organization?(_scope_or_user, nil), do: false

  def can_view_organization?(scope_or_user, org_or_id) do
    scope = ensure_scope(scope_or_user)
    org_id = id_of(org_or_id)

    cond do
      scope.global? -> true
      is_nil(org_id) -> false
      true -> org_id in scope.organization_ids
    end
  end

  @doc """
  Determines if the actor is authorized to manage an organization.
  """
  @spec can_manage_organization?(Scope.t() | User.t(), integer() | String.t() | map() | nil) ::
          boolean()
  def can_manage_organization?(_scope_or_user, nil), do: false

  def can_manage_organization?(scope_or_user, org_or_id) do
    scope = ensure_scope(scope_or_user)
    org_id = id_of(org_or_id)

    cond do
      scope.viewer? -> false
      scope.admin? or scope.editor? -> true
      is_nil(org_id) -> false
      true -> org_id in scope.organization_ids
    end
  end

  # ── Brand Predicates ─────────────────────────────────────────────────────────

  @doc """
  Determines if the actor is authorized to view a brand.
  """
  @spec can_view_brand?(Scope.t() | User.t(), integer() | String.t() | map() | nil) :: boolean()
  def can_view_brand?(_scope_or_user, nil), do: false

  def can_view_brand?(scope_or_user, brand_or_id) do
    scope = ensure_scope(scope_or_user)
    brand_id = id_of(brand_or_id)

    cond do
      scope.global? -> true
      is_nil(brand_id) -> false
      true -> brand_id in scope.brand_ids
    end
  end

  @doc """
  Determines if the actor is authorized to manage a brand.
  """
  @spec can_manage_brand?(Scope.t() | User.t(), integer() | String.t() | map() | nil) :: boolean()
  def can_manage_brand?(_scope_or_user, nil), do: false

  def can_manage_brand?(scope_or_user, brand_or_id) do
    scope = ensure_scope(scope_or_user)
    brand_id = id_of(brand_or_id)

    cond do
      scope.viewer? -> false
      scope.admin? or scope.editor? -> true
      is_nil(brand_id) -> false
      true -> brand_id in scope.brand_ids
    end
  end

  # ── Role Delegation Predicate ────────────────────────────────────────────────

  @doc """
  Determines whether an actor can invite, create, or appoint a target role
  within an optional organizational context (%{brand_id: ..., organization_id: ...}).
  """
  @spec can_delegate_role?(Scope.t() | User.t(), atom() | String.t(), map()) :: boolean()
  def can_delegate_role?(scope_or_user, target_role, context \\ %{})

  def can_delegate_role?(scope_or_user, target_role, context) when is_binary(target_role) do
    case parse_role(target_role) do
      nil -> false
      role_atom -> can_delegate_role?(scope_or_user, role_atom, context)
    end
  end

  def can_delegate_role?(scope_or_user, target_role, context) when is_atom(target_role) do
    scope = ensure_scope(scope_or_user)

    cond do
      # 1. Admin can delegate any role
      scope.admin? ->
        true

      # 2. Global roles (admin, editor, viewer) can NEVER be delegated by non-admins
      target_role in [:admin, :editor, :viewer] ->
        false

      # 3. Editor and Viewer cannot delegate any roles
      scope.editor? or scope.viewer? ->
        false

      # 4. Brand Manager can delegate organization_manager in their brands
      scope.role == :brand_manager and target_role == :organization_manager ->
        brand_id = id_of(context[:brand_id] || context["brand_id"])
        is_nil(brand_id) or brand_id in scope.brand_ids

      # 5. Company Manager can delegate product_owner in their organizations
      scope.role == :organization_manager and target_role == :product_owner ->
        org_id = id_of(context[:organization_id] || context["organization_id"])
        is_nil(org_id) or org_id in scope.organization_ids

      # 6. Delivery Head can delegate supervisors and PMs
      scope.role == :delivery_head and target_role in [:pm_supervisor, :project_manager] ->
        true

      # 7. Supervisor can delegate PMs
      scope.role == :pm_supervisor and target_role == :project_manager ->
        true

      true ->
        false
    end
  end

  @doc """
  Determines whether an actor can generate a one-time login link for a target user.
  Follows the Dual-Tree Scoped RBAC hierarchy:
  - Admin can generate for anyone.
  - Non-admins can NEVER generate for admin, editor, or viewer.
  - Editor and Viewer can NEVER generate login links for anyone.
  - Cannot generate a login link for oneself (use password reset or magic link).
  - Delivery Head can generate for supervisors and PMs.
  - Supervisor can generate for PMs that report directly to them (target_user.supervisor_id == supervisor.id).
  - Brand Manager can generate for Company Managers and POs within their brand portfolio.
  - Company Manager can generate for POs within their organization.
  """
  @spec can_generate_one_time_login?(Scope.t() | User.t(), User.t()) :: boolean()
  def can_generate_one_time_login?(scope_or_user, %User{} = target_user) do
    scope = ensure_scope(scope_or_user)

    cond do
      # 1. Cannot generate for oneself
      scope.user && scope.user.id == target_user.id ->
        false

      # 2. Admin can generate for anyone
      scope.admin? ->
        true

      # 3. Global roles (admin, editor, viewer) can NEVER have login links generated by non-admins
      target_user.role in [:admin, :editor, :viewer] ->
        false

      # 4. Editors and Viewers cannot generate links for anyone
      scope.editor? or scope.viewer? ->
        false

      # 5. Delivery Head can generate for any supervisor or project manager
      scope.role == :delivery_head and target_user.role in [:pm_supervisor, :project_manager] ->
        true

      # 6. Supervisor can generate for their supervised project managers
      scope.role == :pm_supervisor and target_user.role == :project_manager ->
        target_user.supervisor_id == (scope.user && scope.user.id)

      # 7. Brand Manager can generate for Organization Managers and Product Owners in their brand
      scope.role == :brand_manager and target_user.role in [:organization_manager, :product_owner] ->
        target_person = resolve_person(target_user)

        cond do
          is_nil(target_person) ->
            false

          target_person.organization_id && target_person.organization_id in scope.organization_ids ->
            true

          Repo.exists?(
            from o in Organization,
              where: o.id in ^scope.organization_ids and o.manager_id == ^target_person.id
          ) ->
            true

          true ->
            false
        end

      # 8. Organization Manager can generate for Product Owners in their organization
      scope.role == :organization_manager and target_user.role == :product_owner ->
        target_person = resolve_person(target_user)

        not is_nil(target_person) and not is_nil(target_person.organization_id) and
          target_person.organization_id in scope.organization_ids

      true ->
        false
    end
  end

  # ── Internal Resolution Helpers ──────────────────────────────────────────────

  defp resolve_person(%User{} = user) do
    has_id = not is_nil(user.id)
    has_email = is_binary(user.email) and user.email != ""

    cond do
      has_id and has_email ->
        Repo.one(
          from p in Person,
            where: p.user_id == ^user.id or (is_nil(p.user_id) and p.email == ^user.email),
            limit: 1
        )

      has_id ->
        Repo.one(from p in Person, where: p.user_id == ^user.id, limit: 1)

      has_email ->
        Repo.one(from p in Person, where: is_nil(p.user_id) and p.email == ^user.email, limit: 1)

      true ->
        nil
    end
  end

  defp resolve_brand_ids(nil), do: []

  defp resolve_brand_ids(person_id) do
    direct_brand_ids =
      Repo.all(from b in Brand, where: b.brand_manager_id == ^person_id, select: b.id)

    org_brand_ids =
      Repo.all(
        from o in Organization,
          where: o.manager_id == ^person_id and not is_nil(o.brand_id),
          select: o.brand_id
      )

    project_brand_ids =
      Repo.all(
        from pr in ProjectRole,
          join: p in Project,
          on: pr.project_id == p.id,
          join: o in Organization,
          on: p.organization_id == o.id,
          where: pr.person_id == ^person_id and not is_nil(o.brand_id),
          select: o.brand_id
      )

    project_leadership_brand_ids =
      Repo.all(
        from p in Project,
          join: o in Organization,
          on: p.organization_id == o.id,
          where:
            (p.project_manager_id == ^person_id or p.product_owner_id == ^person_id) and
              not is_nil(o.brand_id),
          select: o.brand_id
      )

    Enum.uniq(
      direct_brand_ids ++ org_brand_ids ++ project_brand_ids ++ project_leadership_brand_ids
    )
  end

  defp resolve_organization_ids(brand_ids, person_id) do
    conditions = []

    conditions =
      if brand_ids != [] do
        [dynamic([o], o.brand_id in ^brand_ids) | conditions]
      else
        conditions
      end

    conditions =
      if person_id do
        [dynamic([o], o.manager_id == ^person_id) | conditions]
      else
        conditions
      end

    case conditions do
      [] ->
        []

      [single] ->
        Repo.all(from o in Organization, where: ^single, select: o.id)

      [first | rest] ->
        combined = Enum.reduce(rest, first, fn c, acc -> dynamic([o], ^acc or ^c) end)
        Repo.all(from o in Organization, where: ^combined, select: o.id)
    end
  end

  defp resolve_supervised_pm_ids(%User{role: :delivery_head}) do
    Repo.all(
      from u in User,
        where: u.role in [:pm_supervisor, :project_manager],
        select: u.id
    )
  end

  defp resolve_supervised_pm_ids(%User{role: :pm_supervisor, id: user_id}) do
    Repo.all(
      from u in User,
        where: u.supervisor_id == ^user_id,
        select: u.id
    )
  end

  defp resolve_supervised_pm_ids(_user), do: []

  defp resolve_project_ids(org_ids, person_id, supervised_pm_user_ids) do
    # 1. Projects under accessible organizations
    org_project_ids =
      if org_ids != [] do
        Repo.all(from p in Project, where: p.organization_id in ^org_ids, select: p.id)
      else
        []
      end

    # 2. Projects where the person has a project role OR is project_manager / product_owner
    direct_project_ids =
      if person_id do
        roles_pids =
          Repo.all(
            from pr in ProjectRole,
              where: pr.person_id == ^person_id,
              select: pr.project_id
          )

        leadership_pids =
          Repo.all(
            from p in Project,
              where: p.project_manager_id == ^person_id or p.product_owner_id == ^person_id,
              select: p.id
          )

        roles_pids ++ leadership_pids
      else
        []
      end

    # 3. Projects managed by supervised PMs (via ProjectRole or project_manager_id)
    supervised_project_ids =
      if supervised_pm_user_ids != [] do
        supervised_person_ids =
          Repo.all(
            from p in Person,
              where: p.user_id in ^supervised_pm_user_ids,
              select: p.id
          )

        supervised_role_pids =
          Repo.all(
            from pr in ProjectRole,
              where: pr.person_id in ^supervised_person_ids,
              select: pr.project_id
          )

        supervised_leadership_pids =
          Repo.all(
            from p in Project,
              where: p.project_manager_id in ^supervised_person_ids,
              select: p.id
          )

        supervised_role_pids ++ supervised_leadership_pids
      else
        []
      end

    Enum.uniq(org_project_ids ++ direct_project_ids ++ supervised_project_ids)
  end

  defp resolve_domain_ids(brand_ids, org_ids, project_ids, user_email) do
    conditions = []

    conditions =
      if brand_ids != [] do
        [dynamic([d], d.brand_id in ^brand_ids) | conditions]
      else
        conditions
      end

    conditions =
      if org_ids != [] do
        [dynamic([d], d.organization_id in ^org_ids) | conditions]
      else
        conditions
      end

    conditions =
      if project_ids != [] do
        [dynamic([d], d.project_id in ^project_ids) | conditions]
      else
        conditions
      end

    conditions =
      if is_binary(user_email) and user_email != "" do
        [dynamic([d], d.pm_email == ^user_email or d.po_email == ^user_email) | conditions]
      else
        conditions
      end

    case conditions do
      [] ->
        []

      [single] ->
        Repo.all(from d in Domain, where: ^single, select: d.id)

      [first | rest] ->
        combined = Enum.reduce(rest, first, fn c, acc -> dynamic([d], ^acc or ^c) end)
        Repo.all(from d in Domain, where: ^combined, select: d.id)
    end
  end

  defp id_of(%{id: id}), do: id
  defp id_of(id) when is_integer(id), do: id

  defp id_of(id) when is_binary(id) do
    case Integer.parse(id) do
      {val, ""} -> val
      _ -> nil
    end
  end

  defp id_of(_), do: nil

  defp parse_role(role) when is_binary(role) do
    try do
      String.to_existing_atom(role)
    rescue
      ArgumentError -> nil
    end
  end
end
