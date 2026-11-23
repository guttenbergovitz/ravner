defmodule RavnerWeb.PageControllerTest do
  use RavnerWeb.ConnCase, async: true

  test "GET / redirects to login when not authenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 302)
    assert conn.halted
  end
end
