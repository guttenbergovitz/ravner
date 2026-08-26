defmodule RavnerWeb.HealthController do
  use RavnerWeb, :controller

  def index(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
