defmodule RavnerWeb.PageController do
  use RavnerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
