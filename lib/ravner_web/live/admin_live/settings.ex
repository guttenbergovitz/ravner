defmodule RavnerWeb.AdminLive.Settings do
  use RavnerWeb, :live_view

  alias Ravner.ApiKeys
  alias Ravner.ApiKeys.ApiKey
  alias Ravner.Repo
  alias Ravner.SystemCommand

  @nuclei_template_update_timeout 120_000

  @impl true
  def mount(_params, _session, socket) do
    if admin?(socket.assigns.current_scope) do
      {pa11y_available?, pa11y_version} = check_pa11y()
      nuclei_status = check_nuclei_status()

      last_security_scan = last_scan_time("security_scans")
      last_a11y_scan = last_scan_time("a11y_scans")
      last_lighthouse_scan = last_scan_time("lighthouse_scans")
      lighthouse_ok = System.find_executable("lighthouse") != nil

      {:ok,
       socket
       |> assign(:page_title, "Settings")
       |> assign(:api_keys, ApiKeys.list_api_keys())
       |> assign(:known_keys, ApiKeys.list_known_keys())
       |> assign(:editing_key, nil)
       |> assign(:form, nil)
       |> assign(:pa11y_available?, pa11y_available?)
       |> assign(:pa11y_version, pa11y_version)
       |> assign(:nuclei_status, nuclei_status)
       |> assign(:last_security_scan, last_security_scan)
       |> assign(:last_a11y_scan, last_a11y_scan)
       |> assign(:last_lighthouse_scan, last_lighthouse_scan)
       |> assign(:lighthouse_ok, lighthouse_ok)}
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
  def handle_event("edit_key", %{"name" => name}, socket) do
    api_key = ApiKeys.get_api_key_by_name(name)

    if api_key do
      {:noreply,
       socket
       |> assign(:editing_key, name)
       |> assign(:form, to_form(ApiKeys.change_api_key(api_key)))}
    else
      # New key entry
      {:noreply,
       socket
       |> assign(:editing_key, name)
       |> assign(
         :form,
         to_form(ApiKeys.change_api_key(%ApiKey{name: name, key_type: "settings"}))
       )}
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_key, nil)
     |> assign(:form, nil)}
  end

  @impl true
  def handle_event("save_key", %{"api_key" => attrs}, socket) do
    name = socket.assigns.editing_key
    existing = ApiKeys.get_api_key_by_name(name)

    attrs = Map.put(attrs, "name", name)

    result =
      if existing do
        ApiKeys.update_api_key(existing, attrs)
      else
        ApiKeys.create_api_key(attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:api_keys, ApiKeys.list_api_keys())
         |> assign(:editing_key, nil)
         |> assign(:form, nil)
         |> put_flash(:info, "API key saved")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_key", %{"id" => id}, socket) do
    key = ApiKeys.get_api_key!(id)
    {:ok, _} = ApiKeys.delete_api_key(key)

    {:noreply,
     socket
     |> assign(:api_keys, ApiKeys.list_api_keys())
     |> put_flash(:info, "API key removed")}
  end

  @impl true
  def handle_event("validate_key", %{"name" => name}, socket) do
    case ApiKeys.validate_key(name) do
      {:ok, :valid} ->
        {:noreply,
         socket
         |> assign(:api_keys, ApiKeys.list_api_keys())
         |> put_flash(:info, "#{name} key is valid")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:api_keys, ApiKeys.list_api_keys())
         |> put_flash(:error, "#{name} validation failed: #{reason}")}
    end
  end

  @impl true
  def handle_event("update_nuclei_templates", _params, socket) do
    liveview_pid = self()

    Task.Supervisor.start_child(Ravner.ScanTaskSupervisor, fn ->
      send(liveview_pid, {:nuclei_templates_updated, update_nuclei_templates()})
    end)

    {:noreply, put_flash(socket, :info, "Nuclei template update started")}
  end

  @impl true
  def handle_info({:nuclei_templates_updated, result}, socket) do
    case result do
      {_output, 0} ->
        {:noreply,
         socket
         |> put_flash(:info, "Nuclei templates updated successfully")}

      {:error, :timeout} ->
        {:noreply,
         socket
         |> put_flash(:error, "Nuclei template update timed out")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Nuclei template update failed: #{reason}")}

      {output, _code} ->
        {:noreply,
         socket
         |> put_flash(:error, "Nuclei template update failed: #{String.slice(output, 0, 200)}")}
    end
  end

  defp admin?(nil), do: false

  defp admin?(scope) do
    scope.user && scope.user.role == :admin
  end

  defp update_nuclei_templates do
    SystemCommand.run_with_timeout(
      "nuclei",
      ["-update-templates"],
      @nuclei_template_update_timeout
    )
  end

  @nuclei_template_paths ["/app/.nuclei-templates", "/app/nuclei-templates", "/root/nuclei-templates"]

  defp check_nuclei_status do
    available? = System.find_executable("nuclei") != nil

    templates_path = Enum.find(@nuclei_template_paths, &File.dir?/1)

    {templates_count, templates_date} =
      if templates_path do
        count =
          case System.cmd("find", [templates_path, "-name", "*.yaml", "-type", "f"], stderr_to_stdout: true) do
            {output, 0} -> output |> String.split("\n", trim: true) |> length()
            _ -> 0
          end

        date =
          case File.stat(templates_path) do
            {:ok, %{mtime: mtime}} ->
              mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_date() |> Date.to_iso8601()
            _ -> nil
          end

        {count, date}
      else
        {0, nil}
      end

    %{
      available?: available?,
      templates_path: templates_path,
      templates_count: templates_count,
      templates_date: templates_date
    }
  end

  defp check_pa11y do
    case System.find_executable("pa11y") do
      nil ->
        {false, nil}

      _path ->
        case System.cmd("pa11y", ["--version"], stderr_to_stdout: true) do
          {version, 0} -> {true, String.trim(version)}
          _ -> {true, "unknown"}
        end
    end
  end

  defp last_scan_time(table) do
    import Ecto.Query
    Repo.one(from(s in table, where: s.status == "completed", select: max(s.completed_at)))
  end
end
