defmodule RavnerWeb.OwnershipLive.Delivery do
  @moduledoc """
  LiveView for Delivery & PM Hierarchy management.
  Provides a cross-company view of Delivery Heads, PM Supervisors, and Project Managers
  with supervisor assignments, invite workflows, and one-time login links.
  """
  use RavnerWeb, :live_view

  alias Ravner.Accounts
  alias Ravner.Accounts.{ScopeResolver, User}
  alias Ravner.Repo
  import Ecto.Query

  @allowed_roles [:admin, :editor, :delivery_head, :pm_supervisor, :project_manager]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:current_scope]

    if scope && scope.role not in @allowed_roles do
      {:ok,
       socket
       |> put_flash(:error, "You do not have permission to view the Delivery hierarchy.")
       |> push_navigate(to: ~p"/ownership")}
    else
      {:ok, load_delivery_state(socket)}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("generate_one_time_login", %{"user_id" => user_id_param}, socket) do
    target_user = Repo.get(User, user_id_param)
    actor = socket.assigns.current_scope.user

    url_fun = fn token ->
      Phoenix.VerifiedRoutes.url(socket, ~p"/users/log-in/one-time/#{token}")
    end

    case Accounts.generate_one_time_login_link(target_user, actor, url_fun) do
      {:ok, link} ->
        {:noreply,
         socket
         |> assign(:one_time_login_link, link)
         |> assign(:one_time_login_user, target_user)}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You do not have permission to generate a login link for this user."
         )}

      {:error, :inactive} ->
        {:noreply,
         put_flash(socket, :error, "Cannot generate a login link for an inactive user.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to generate login link.")}
    end
  end

  @impl true
  def handle_event("close_one_time_login", _params, socket) do
    {:noreply,
     socket
     |> assign(:one_time_login_link, nil)
     |> assign(:one_time_login_user, nil)}
  end

  @impl true
  def handle_event("open_invite_delivery", _params, socket) do
    {:noreply,
     socket
     |> assign(:inviting_delivery?, true)
     |> assign(:generated_invite_link, nil)
     |> assign(
       :delivery_invite_form,
       to_form(%{"email" => "", "name" => "", "role" => "project_manager", "supervisor_id" => ""},
         as: :invite
       )
     )}
  end

  @impl true
  def handle_event("close_invite_delivery", _params, socket) do
    {:noreply,
     socket
     |> assign(:inviting_delivery?, false)
     |> assign(:generated_invite_link, nil)}
  end

  @impl true
  def handle_event("send_delivery_invite", %{"invite" => params}, socket) do
    actor = socket.assigns.current_scope.user
    email = Map.get(params, "email", "")
    target_role = Map.get(params, "role", "project_manager")
    supervisor_id = parse_id(Map.get(params, "supervisor_id"))

    target_role_atom =
      case target_role do
        "pm_supervisor" -> :pm_supervisor
        _ -> :project_manager
      end

    if ScopeResolver.can_delegate_role?(socket.assigns.current_scope, target_role_atom, %{}) do
      invite_attrs =
        %{
          "email" => email,
          "role" => Atom.to_string(target_role_atom)
        }
        |> then(fn attrs ->
          if supervisor_id, do: Map.put(attrs, "supervisor_id", supervisor_id), else: attrs
        end)

      case Accounts.create_invite(invite_attrs, actor.id, actor: actor) do
        {:ok, invite} ->
          invite_link =
            Phoenix.VerifiedRoutes.url(socket, ~p"/users/invite/#{invite.token}")

          {:noreply,
           socket
           |> assign(:generated_invite_link, invite_link)
           |> put_flash(:info, "Invitation created for #{email}.")}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, "You do not have permission to invite this role.")}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, assign(socket, :delivery_invite_form, to_form(cs, as: :invite))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not create invite.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Authorization denied.")}
    end
  end

  @impl true
  def handle_event("reassign_supervisor", %{"pm_id" => pm_id, "supervisor_id" => sup_id}, socket) do
    actor = socket.assigns.current_scope.user

    if socket.assigns.can_manage_delivery? do
      pm_user = Repo.get!(User, pm_id)
      supervisor_id = parse_id(sup_id)

      case Accounts.admin_update_user(pm_user, %{supervisor_id: supervisor_id}, actor: actor) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "Project Manager supervisor updated.")
           |> load_delivery_state()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to reassign supervisor.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to reassign supervisors.")}
    end
  end

  defp load_delivery_state(socket) do
    scope = socket.assigns.current_scope

    can_manage_delivery? =
      is_nil(scope) or scope.admin? or scope.editor? or scope.role == :delivery_head

    can_delegate_delivery? =
      is_nil(scope) or
        ScopeResolver.can_delegate_role?(scope, :project_manager, %{}) or
        ScopeResolver.can_delegate_role?(scope, :pm_supervisor, %{})

    delivery_heads =
      Repo.all(
        from u in User,
          where: u.role == :delivery_head and u.active == true,
          preload: [:person],
          order_by: [asc: u.name, asc: u.email]
      )

    supervisors_query =
      from u in User,
        where: u.role == :pm_supervisor and u.active == true,
        preload: [:person, subordinates: [:person]],
        order_by: [asc: u.name, asc: u.email]

    supervisors =
      if scope && scope.role == :pm_supervisor do
        Repo.all(from q in supervisors_query, where: q.id == ^scope.user.id)
      else
        Repo.all(supervisors_query)
      end

    pm_query =
      from u in User,
        where: u.role == :project_manager and u.active == true,
        preload: [:person, :supervisor],
        order_by: [asc: u.name, asc: u.email]

    raw_pms =
      cond do
        scope && scope.role == :pm_supervisor ->
          Repo.all(from q in pm_query, where: q.supervisor_id == ^scope.user.id)

        scope && scope.role == :project_manager ->
          Repo.all(from q in pm_query, where: q.id == ^scope.user.id)

        true ->
          Repo.all(pm_query)
      end

    person_ids =
      raw_pms
      |> Enum.map(&(&1.person && &1.person.id))
      |> Enum.reject(&is_nil/1)

    leadership_projects =
      if person_ids != [] do
        from(p in Ravner.Inventory.Project,
          where: p.project_manager_id in ^person_ids,
          preload: [:organization]
        )
        |> Repo.all()
        |> Enum.group_by(& &1.project_manager_id)
      else
        %{}
      end

    role_projects =
      if person_ids != [] do
        from(pr in Ravner.Inventory.ProjectRole,
          where: pr.person_id in ^person_ids,
          join: p in assoc(pr, :project),
          preload: [project: :organization]
        )
        |> Repo.all()
        |> Enum.group_by(& &1.person_id, & &1.project)
      else
        %{}
      end

    pms =
      Enum.map(raw_pms, fn pm ->
        pid = pm.person && pm.person.id
        direct = Map.get(leadership_projects, pid, [])
        from_roles = Map.get(role_projects, pid, [])
        all_proj = Enum.uniq_by(direct ++ from_roles, & &1.id)
        Map.put(pm, :assigned_projects, all_proj)
      end)

    unassigned_pms =
      if can_manage_delivery? do
        Enum.filter(pms, &is_nil(&1.supervisor_id))
      else
        []
      end

    socket
    |> assign(:page_title, "Delivery & PM Hierarchy")
    |> assign(:delivery_heads, delivery_heads)
    |> assign(:supervisors, supervisors)
    |> assign(:pms, pms)
    |> assign(:unassigned_pms, unassigned_pms)
    |> assign(:can_manage_delivery?, can_manage_delivery?)
    |> assign(:can_delegate_delivery?, can_delegate_delivery?)
    |> assign(:inviting_delivery?, false)
    |> assign(:generated_invite_link, nil)
    |> assign(:one_time_login_link, nil)
    |> assign(:one_time_login_user, nil)
    |> assign(
      :delivery_invite_form,
      to_form(%{"email" => "", "name" => "", "role" => "project_manager", "supervisor_id" => ""},
        as: :invite
      )
    )
  end

  defp parse_id(param) when param in ["", "none", nil], do: nil
  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> int
      :error -> nil
    end
  end
end
