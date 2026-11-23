defmodule RavnerWeb.Plugs.RequireRole do
  @moduledoc """
  Plug that ensures the current user has at least the required role.

  Role hierarchy: admin > editor > viewer

  Usage in router:
    plug RavnerWeb.Plugs.RequireRole, :admin
    plug RavnerWeb.Plugs.RequireRole, :editor
  """

  import Plug.Conn
  import Phoenix.Controller

  @role_rank %{viewer: 0, editor: 1, admin: 2}

  def init(required_role), do: required_role

  def call(conn, required_role) do
    user = conn.assigns[:current_scope] && conn.assigns.current_scope.user

    if authorized?(user, required_role) do
      conn
    else
      conn
      |> put_flash(:error, "You don't have permission to access this page.")
      |> redirect(to: "/domains")
      |> halt()
    end
  end

  def authorized?(nil, _required), do: false

  def authorized?(user, :editor) do
    user.role in [
      :admin,
      :editor,
      :brand_manager,
      :organization_manager,
      :product_owner,
      :delivery_head,
      :pm_supervisor,
      :project_manager
    ]
  end

  def authorized?(user, required_role) do
    Map.get(@role_rank, user.role, 0) >= Map.get(@role_rank, required_role, 99)
  end
end
