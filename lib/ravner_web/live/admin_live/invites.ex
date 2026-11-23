defmodule RavnerWeb.AdminLive.Invites do
  use RavnerWeb, :live_view

  alias Ravner.Accounts
  alias Ravner.Accounts.User
  alias Ravner.Inventory

  @impl true
  def mount(_params, _session, socket) do
    role_options = Enum.map(User.roles(), &{User.role_label(&1), Atom.to_string(&1)})

    projects = Inventory.list_projects()
    brands = Inventory.list_brands()
    orgs = Inventory.list_organizations()

    project_options =
      [{"None (Unassigned)", ""}] ++
        Enum.map(projects, fn p ->
          label = if p.organization, do: "#{p.name} (#{p.organization.name})", else: p.name
          {label, to_string(p.id)}
        end)

    brand_options =
      [{"None (Unassigned)", ""}] ++
        Enum.map(brands, &{&1.name, to_string(&1.id)})

    org_options =
      [{"None (Unassigned)", ""}] ++
        Enum.map(orgs, &{&1.name, to_string(&1.id)})

    project_names = Map.new(projects, &{&1.id, &1.name})
    brand_names = Map.new(brands, &{&1.id, &1.name})
    org_names = Map.new(orgs, &{&1.id, &1.name})

    supervisor_options =
      [{"None", ""}] ++
        (Accounts.list_users()
         |> Enum.filter(&(&1.role in [:admin, :delivery_head, :pm_supervisor]))
         |> Enum.map(fn u ->
           label = if u.name && u.name != "", do: "#{u.name} (#{u.email})", else: u.email
           {"#{label} [#{User.role_label(u.role)}]", to_string(u.id)}
         end))

    {:ok,
     socket
     |> assign(:invites, Accounts.list_invites())
     |> assign(:active_tab, :invites)
     |> assign(:role_options, role_options)
     |> assign(:supervisor_options, supervisor_options)
     |> assign(:project_options, project_options)
     |> assign(:brand_options, brand_options)
     |> assign(:org_options, org_options)
     |> assign(:project_names, project_names)
     |> assign(:brand_names, brand_names)
     |> assign(:org_names, org_names)
     |> assign(:selected_invite_link, nil)
     |> assign(:page_title, "Invites")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    form =
      to_form(
        %{
          "email" => "",
          "name" => "",
          "role" => "viewer",
          "supervisor_id" => "",
          "target_project_id" => "",
          "target_brand_id" => "",
          "target_organization_id" => ""
        },
        as: :invite
      )

    socket |> assign(:form, form)
  end

  @impl true
  def handle_event("validate", %{"invite" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :invite))}
  end

  @impl true
  def handle_event("send_invite", %{"invite" => params}, socket) do
    actor = socket.assigns.current_scope.user
    invited_by_id = actor.id

    parse_id = fn
      "" -> nil
      nil -> nil
      id when is_binary(id) -> String.to_integer(id)
      id -> id
    end

    parsed_params =
      params
      |> Map.update("supervisor_id", nil, parse_id)
      |> Map.update("target_project_id", nil, parse_id)
      |> Map.update("target_brand_id", nil, parse_id)
      |> Map.update("target_organization_id", nil, parse_id)

    case Accounts.create_invite(parsed_params, invited_by_id, actor: actor) do
      {:ok, invite} ->
        invite_url = url(~p"/users/invite/#{invite.token}")

        {:noreply,
         socket
         |> assign(:selected_invite_link, invite_url)
         |> assign(:invites, Accounts.list_invites())
         |> push_patch(to: ~p"/admin/invites")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not create invite.")}
    end
  end

  @impl true
  def handle_event("show_invite_link", %{"token" => token}, socket) do
    invite_url = url(~p"/users/invite/#{token}")
    {:noreply, assign(socket, :selected_invite_link, invite_url)}
  end

  @impl true
  def handle_event("close_invite_link", _params, socket) do
    {:noreply, assign(socket, :selected_invite_link, nil)}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/invites")}
  end
end
