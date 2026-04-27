defmodule RavnerWeb.PageController do
  use RavnerWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
      redirect(conn, to: ~p"/domains")
    else
      render(conn, :home)
    end
  end
end
