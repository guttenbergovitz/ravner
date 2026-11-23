defmodule Ravner.Accounts.ScopeCheck do
  @moduledoc """
  Ash policy check that enforces Scoped RBAC governance permissions by delegating
  to `Ravner.Accounts.ScopeResolver` and `Ravner.Accounts.Scope`.
  """
  use Ash.Policy.SimpleCheck

  import Ecto.Query
  alias Ravner.Accounts.{Scope, ScopeResolver, User}
  alias Ravner.Inventory.Person
  alias Ravner.Repo

  @impl true
  def describe(opts) do
    "authorized by ScopeResolver for #{inspect(opts[:permission])}"
  end

  @impl true
  def match?(nil, _ctx, _opts), do: {:ok, false}

  def match?(%User{} = actor, %{subject: %Ash.Changeset{} = changeset}, opts) do
    scope = Scope.for_user(actor)

    res =
      cond do
        # 1. Admin always authorized
        scope.admin? ->
          true

        # 2. Viewers can never perform any write action
        scope.viewer? ->
          false

        # 3. Editors have full technical/operational write access, except for user role delegation/invites
        scope.editor? ->
          opts[:permission] != :delegate_invite

        true ->
          evaluate_scoped_permission(scope, changeset, opts[:permission])
      end

    {:ok, res == true}
  end

  def match?(%User{} = actor, %{subject: %Ash.Query{}}, _opts) do
    scope = Scope.for_user(actor)
    {:ok, scope.admin? or scope.editor?}
  end

  def match?(_actor, _ctx, _opts), do: {:ok, false}

  # ── Scoped Permission Evaluator ──────────────────────────────────────────────

  defp evaluate_scoped_permission(scope, changeset, :manage_brand) do
    scope.admin? or (scope.editor? and changeset.action_type == :update)
  end

  defp evaluate_scoped_permission(scope, changeset, :manage_organization) do
    record = changeset.data
    brand_id = Ash.Changeset.get_attribute(changeset, :brand_id) || (record && record.brand_id)
    org_id = record && record.id

    cond do
      scope.role == :brand_manager ->
        (is_integer(brand_id) and brand_id in scope.brand_ids) or
          (is_integer(org_id) and org_id in scope.organization_ids)

      scope.role == :organization_manager ->
        changeset.action_type == :update and is_integer(org_id) and
          org_id in scope.organization_ids

      true ->
        false
    end
  end

  defp evaluate_scoped_permission(scope, changeset, :manage_project) do
    record = changeset.data

    org_id =
      Ash.Changeset.get_attribute(changeset, :organization_id) ||
        (record && record.organization_id)

    project_id = record && record.id

    cond do
      scope.role in [:brand_manager, :organization_manager] ->
        (is_integer(org_id) and org_id in scope.organization_ids) or
          (is_integer(project_id) and project_id in scope.project_ids)

      scope.role in [:delivery_head, :pm_supervisor, :project_manager, :product_owner] ->
        is_integer(project_id) and project_id in scope.project_ids

      true ->
        false
    end
  end

  defp evaluate_scoped_permission(scope, changeset, :manage_project_role) do
    record = changeset.data

    project_id =
      Ash.Changeset.get_attribute(changeset, :project_id) || (record && record.project_id)

    cond do
      scope.role == :delivery_head ->
        true

      scope.role in [:pm_supervisor, :project_manager, :brand_manager, :organization_manager] ->
        is_integer(project_id) and project_id in scope.project_ids

      true ->
        false
    end
  end

  defp evaluate_scoped_permission(scope, changeset, :manage_person) do
    record = changeset.data

    org_id =
      Ash.Changeset.get_attribute(changeset, :organization_id) ||
        (record && record.organization_id)

    cond do
      scope.role in [:brand_manager, :organization_manager] ->
        is_integer(org_id) and org_id in scope.organization_ids

      true ->
        false
    end
  end

  defp evaluate_scoped_permission(scope, changeset, :delegate_invite) do
    target_role = Ash.Changeset.get_attribute(changeset, :role)
    brand_id = Ash.Changeset.get_attribute(changeset, :target_brand_id)
    org_id = Ash.Changeset.get_attribute(changeset, :target_organization_id)
    supervisor_id = Ash.Changeset.get_attribute(changeset, :supervisor_id)

    cond do
      is_nil(target_role) ->
        false

      scope.role == :pm_supervisor and target_role in [:project_manager, "project_manager"] ->
        is_nil(supervisor_id) or supervisor_id == scope.user.id

      true ->
        ScopeResolver.can_delegate_role?(scope, target_role, %{
          brand_id: brand_id,
          organization_id: org_id
        })
    end
  end

  defp evaluate_scoped_permission(scope, changeset, :manage_user) do
    record = changeset.data

    cond do
      scope.role == :pm_supervisor ->
        record != nil and record.role == :project_manager and
          record.supervisor_id == scope.user.id

      scope.role == :delivery_head ->
        record != nil and record.role in [:pm_supervisor, :project_manager]

      scope.role in [:brand_manager, :organization_manager] ->
        if record do
          target_person = Repo.one(from p in Person, where: p.user_id == ^record.id, limit: 1)

          target_person != nil and is_integer(target_person.organization_id) and
            target_person.organization_id in scope.organization_ids
        else
          false
        end

      true ->
        false
    end
  end
end
