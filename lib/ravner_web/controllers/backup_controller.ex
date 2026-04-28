defmodule RavnerWeb.BackupController do
  use RavnerWeb, :controller

  alias Ravner.Admin.Backups

  def download(conn, _params) do
    case Backups.create_dump() do
      {:ok, content} ->
        timestamp =
          DateTime.utc_now()
          |> Calendar.strftime("%Y%m%d_%H%M%S")

        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"ravner_business_#{timestamp}.dump\""
        )
        |> send_resp(200, content)

      {:error, reason} ->
        conn
        |> put_flash(:error, "Export failed: #{reason}")
        |> redirect(to: ~p"/admin/settings/backup")
    end
  end
end
