defmodule RavnerWeb.AdminLive.Backup do
  use RavnerWeb, :live_view

  alias Ravner.Admin.Backups

  @impl true
  def mount(_params, _session, socket) do
    if admin?(socket.assigns.current_scope) do
      {:ok,
       socket
       |> assign(:page_title, "Backup & Restore")
       |> assign(:restore_preview, nil)
       |> assign(:restore_path, nil)
       |> assign(:restoring, false)
       |> allow_upload(:backup_file,
         accept: ~w(.json),
         max_entries: 1,
         max_file_size: 10_000_000
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Admin access required")
       |> push_navigate(to: ~p"/domains")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("upload", _params, socket) do
    case uploaded_entries(socket, :backup_file) do
      {[%{} = entry], []} ->
        path =
          consume_uploaded_entry(socket, entry, fn %{path: tmp_path} ->
            dest = Path.join(System.tmp_dir!(), "ravner_restore_#{timestamp()}.dump")
            File.cp!(tmp_path, dest)
            {:ok, dest}
          end)

        case Backups.list_dump_contents(path) do
          {:ok, lines} ->
            {:noreply,
             socket
             |> assign(:restore_preview, lines)
             |> assign(:restore_path, path)}

          {:error, reason} ->
            File.rm(path)
            {:noreply, put_flash(socket, :error, "Invalid dump file: #{reason}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Please select a .dump file")}
    end
  end

  @impl true
  def handle_event("confirm_restore", _params, socket) do
    path = socket.assigns.restore_path

    if path && File.exists?(path) do
      socket = assign(socket, :restoring, true)

      case Backups.restore(path) do
        :ok ->
          File.rm(path)

          {:noreply,
           socket
           |> assign(:restore_preview, nil)
           |> assign(:restore_path, nil)
           |> assign(:restoring, false)
           |> put_flash(:info, "Database restored successfully")}

        {:error, reason} ->
          File.rm(path)

          {:noreply,
           socket
           |> assign(:restoring, false)
           |> put_flash(:error, "Restore failed: #{reason}")}
      end
    else
      {:noreply, put_flash(socket, :error, "No restore file found")}
    end
  end

  @impl true
  def handle_event("cancel_restore", _params, socket) do
    if socket.assigns.restore_path do
      File.rm(socket.assigns.restore_path)
    end

    {:noreply,
     socket
     |> assign(:restore_preview, nil)
     |> assign(:restore_path, nil)}
  end

  defp admin?(nil), do: false

  defp admin?(scope) do
    scope.user && scope.user.role == :admin
  end

  defp timestamp do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%d_%H%M%S")
  end
end
