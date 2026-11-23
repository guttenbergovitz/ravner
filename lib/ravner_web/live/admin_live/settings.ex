defmodule RavnerWeb.AdminLive.Settings do
  use RavnerWeb, :live_view

  alias Ravner.ApiKeys
  alias Ravner.ApiKeys.ApiKey
  alias Ravner.Integrations.VCS
  alias Ravner.Integrations.VcsIntegration
  alias Ravner.Repo
  alias Ravner.SystemCommand

  @nuclei_template_update_timeout 120_000

  @impl true
  def mount(_params, _session, socket) do
    if admin?(socket.assigns.current_scope) do
      {pa11y_available?, pa11y_version} = check_pa11y()
      nuclei_status = check_nuclei_status()
      lonkero_status = check_lonkero_status()
      scan_config = Ravner.ScanConfig.get()
      vcs_status = VCS.status("bitbucket")
      wappalyzer_status = check_wappalyzer_status()

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
       |> assign(:vcs_status, vcs_status)
       |> assign(:vcs_editing?, false)
       |> assign(:vcs_form, nil)
       |> assign(:wappalyzer_status, wappalyzer_status)
       |> assign(:pa11y_available?, pa11y_available?)
       |> assign(:pa11y_version, pa11y_version)
       |> assign(:nuclei_status, nuclei_status)
       |> assign(:lonkero_status, lonkero_status)
       |> assign(:scan_config, scan_config)
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
  def handle_event("toggle_severity", %{"severity" => severity}, socket) do
    config = socket.assigns.scan_config
    current = config.nuclei_severities

    updated =
      if severity in current,
        do: List.delete(current, severity),
        else: current ++ [severity]

    case Ravner.ScanConfig.update(%{nuclei_severities: updated}) do
      {:ok, new_config} -> {:noreply, assign(socket, :scan_config, new_config)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update config")}
    end
  end

  @impl true
  def handle_event("toggle_exclude_tag", %{"tag" => tag}, socket) do
    config = socket.assigns.scan_config
    current = config.nuclei_exclude_tags

    updated =
      if tag in current,
        do: List.delete(current, tag),
        else: current ++ [tag]

    case Ravner.ScanConfig.update(%{nuclei_exclude_tags: updated}) do
      {:ok, new_config} -> {:noreply, assign(socket, :scan_config, new_config)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update config")}
    end
  end

  @impl true
  def handle_event("select_all_severities", _params, socket) do
    case Ravner.ScanConfig.update(%{nuclei_severities: Ravner.ScanConfig.valid_severities()}) do
      {:ok, new_config} -> {:noreply, assign(socket, :scan_config, new_config)}
      {:error, _} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("deselect_all_severities", _params, socket) do
    case Ravner.ScanConfig.update(%{nuclei_severities: ["critical"]}) do
      {:ok, new_config} ->
        {:noreply,
         assign(socket, :scan_config, new_config)
         |> put_flash(:info, "At least critical severity is always enabled")}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_security_scanner", %{"scanner" => scanner}, socket) do
    case Ravner.ScanConfig.update(%{security_scanner: scanner}) do
      {:ok, new_config} ->
        {:noreply,
         socket
         |> assign(:scan_config, new_config)
         |> put_flash(:info, "Security scanner updated to #{scanner}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update security scanner")}
    end
  end

  @impl true
  def handle_event("set_security_scan_mode", %{"mode" => mode}, socket) do
    case Ravner.ScanConfig.update(%{security_scan_mode: mode}) do
      {:ok, new_config} ->
        {:noreply,
         socket
         |> assign(:scan_config, new_config)
         |> put_flash(:info, "Default security scan mode updated to #{mode}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update security scan mode")}
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
  def handle_event("toggle_fallback_tag", %{"tag" => tag}, socket) do
    config = socket.assigns.scan_config
    current = config.nuclei_tags || []

    updated =
      if tag in current,
        do: List.delete(current, tag),
        else: current ++ [tag]

    case Ravner.ScanConfig.update(%{nuclei_tags: updated}) do
      {:ok, new_config} -> {:noreply, assign(socket, :scan_config, new_config)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update config")}
    end
  end

  @impl true
  def handle_event("update_wappalyzer_technologies", _params, socket) do
    liveview_pid = self()

    Task.Supervisor.start_child(Ravner.ScanTaskSupervisor, fn ->
      result = Ravner.Workers.TechnologiesUpdateWorker.perform(%Oban.Job{})
      send(liveview_pid, {:wappalyzer_technologies_updated, result})
    end)

    {:noreply, put_flash(socket, :info, "Technology definitions update started")}
  end

  @impl true
  def handle_event("edit_vcs", params, socket) do
    provider = params["provider"] || "bitbucket"
    status = VCS.status(provider)

    form =
      if status.active_integration do
        # Clear token in the form so plaintext credentials never enter LiveView socket assigns
        to_form(VCS.change_integration(%{status.active_integration | token: nil}))
      else
        to_form(
          VCS.change_integration(%VcsIntegration{
            name: "#{String.capitalize(provider)} Integration",
            provider: provider,
            active: true
          })
        )
      end

    {:noreply,
     socket
     |> assign(:vcs_editing_provider, provider)
     |> assign(:vcs_editing?, true)
     |> assign(:vcs_form, form)}
  end

  @impl true
  def handle_event("cancel_edit_vcs", _params, socket) do
    {:noreply,
     socket
     |> assign(:vcs_editing?, false)
     |> assign(:vcs_form, nil)}
  end

  @impl true
  def handle_event("validate_vcs", %{"vcs_integration" => attrs}, socket) do
    status = socket.assigns.vcs_status

    integration =
      if status.active_integration && status.active_integration.id do
        %{status.active_integration | token: nil}
      else
        %VcsIntegration{
          name: "Bitbucket Integration",
          provider: "bitbucket",
          active: true
        }
      end

    changeset =
      integration
      |> VCS.change_integration(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :vcs_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_vcs", %{"vcs_integration" => attrs}, socket) do
    provider = attrs["provider"] || socket.assigns[:vcs_editing_provider] || "bitbucket"
    status = VCS.status(provider)
    attrs = Map.merge(attrs, %{"provider" => provider, "active" => true})

    attrs =
      if is_nil(attrs["name"]) or attrs["name"] == "" do
        Map.put(attrs, "name", "#{String.capitalize(provider)} Integration")
      else
        attrs
      end

    result =
      if status.active_integration && status.active_integration.id do
        integration = Ravner.Repo.get!(VcsIntegration, status.active_integration.id)
        VCS.update_integration(integration, attrs)
      else
        VCS.create_integration(attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:vcs_status, VCS.status("bitbucket"))
         |> assign(:vcs_editing?, false)
         |> assign(:vcs_form, nil)
         |> put_flash(:info, "VCS credentials saved successfully")}

      {:error, changeset} ->
        {:noreply, assign(socket, :vcs_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_vcs", params, socket) do
    provider = params["provider"] || "bitbucket"
    status = VCS.status(provider)

    if status.active_integration && status.active_integration.id do
      integration = Ravner.Repo.get!(VcsIntegration, status.active_integration.id)
      {:ok, _} = VCS.delete_integration(integration)

      {:noreply,
       socket
       |> assign(:vcs_status, VCS.status("bitbucket"))
       |> put_flash(:info, "#{String.capitalize(provider)} integration removed from database")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("test_vcs", params, socket) do
    provider = params["provider"] || "bitbucket"

    case VCS.resolve_credentials(provider) do
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No #{String.capitalize(provider)} credentials configured to test"
         )}

      creds ->
        case VCS.test_connection(provider, creds) do
          :ok ->
            {:noreply,
             put_flash(
               socket,
               :info,
               "#{String.capitalize(provider)} connection successful (workspace: #{creds.workspace})"
             )}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "#{String.capitalize(provider)} connection failed: #{reason}"
             )}
        end
    end
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

  @impl true
  def handle_info({:wappalyzer_technologies_updated, result}, socket) do
    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(:wappalyzer_status, check_wappalyzer_status())
         |> put_flash(:info, "Wappalyzer technology definitions updated successfully")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Technology definitions update failed: #{reason}")}
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

  @nuclei_template_paths [
    "/app/.nuclei-templates",
    "/app/nuclei-templates",
    "/root/nuclei-templates"
  ]

  defp check_nuclei_status do
    available? = System.find_executable("nuclei") != nil

    templates_path = Enum.find(@nuclei_template_paths, &File.dir?/1)

    {templates_count, templates_date} =
      if templates_path do
        count =
          templates_path
          |> Path.join("**/*.yaml")
          |> Path.wildcard()
          |> length()

        date =
          case File.stat(templates_path) do
            {:ok, %{mtime: mtime}} ->
              mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_date() |> Date.to_iso8601()

            _ ->
              nil
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

  defp check_lonkero_status do
    available? = System.find_executable("lonkero") != nil

    version =
      if available? do
        case SystemCommand.run_with_timeout("lonkero", ["version"], 5_000) do
          {out, 0} ->
            out |> String.trim() |> String.split("\n") |> List.first() || "unknown"

          _ ->
            "unknown"
        end
      else
        nil
      end

    %{
      available?: available?,
      version: version
    }
  end

  defp check_pa11y do
    case System.find_executable("pa11y") do
      nil ->
        {false, nil}

      _path ->
        case SystemCommand.run_with_timeout("pa11y", ["--version"], 5_000) do
          {version, 0} -> {true, String.trim(version)}
          _ -> {true, "unknown"}
        end
    end
  end

  defp last_scan_time(table) do
    import Ecto.Query
    Repo.one(from(s in table, where: s.status == "completed", select: max(s.completed_at)))
  end

  defp check_wappalyzer_status do
    case Ravner.Scans.TechFingerprint.technologies_path() do
      nil ->
        %{
          available?: false,
          path: Ravner.Scans.TechFingerprint.storage_path(),
          updated_at: nil
        }

      path ->
        updated_at =
          case File.stat(path) do
            {:ok, %{mtime: mtime}} ->
              mtime
              |> NaiveDateTime.from_erl!()
              |> DateTime.from_naive!("Etc/UTC")

            _ ->
              nil
          end

        %{available?: true, path: path, updated_at: updated_at}
    end
  end
end
