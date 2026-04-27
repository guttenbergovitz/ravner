defmodule RavnerWeb.Plugs.RequireSetup do
  @moduledoc """
  Redirects to /setup if no users exist in the database.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Ravner.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    if Accounts.has_users?() || conn.request_path == "/setup" do
      conn
    else
      conn
      |> redirect(to: "/setup")
      |> halt()
    end
  end
end
