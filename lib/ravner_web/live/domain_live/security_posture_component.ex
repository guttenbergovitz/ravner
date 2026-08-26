defmodule RavnerWeb.DomainLive.SecurityPostureComponent do
  @moduledoc """
  LiveComponent encapsulating the Security Posture view and manual triggers.
  """
  use RavnerWeb, :live_component

  alias Ravner.Repo
  alias Ravner.Scans.SecurityRunner
  alias Ravner.SecurityScans

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :show_findings_modal, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="security-posture-component">
      <div class="card-line">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-normal tracking-wide uppercase">Security Posture</h2>
          <%= if @running_security_scan && @current_scope && @current_scope.user.role == :admin do %>
            <button
              phx-click="clear_scans"
              phx-target={@myself}
              class="text-neutral-400 hover:text-red-600 transition-colors"
              data-confirm="Force clear the running security scan for this domain?"
              title="Clear scan"
            >
              <.icon name="hero-x-circle" class="w-4 h-4" />
            </button>
          <% end %>
        </div>

        <div class="flex flex-col gap-3 mb-6">
          <%= if @domain.technical_status == :redirect do %>
            <p class="text-[10px] text-neutral-400 italic text-center py-1">
              Security scan unavailable — domain redirects externally
            </p>
          <% else %>
            <%= if @current_scope && @current_scope.user.role in [:admin, :editor] do %>
              <button
                phx-click="run_security_scan"
                phx-target={@myself}
                id="run-security-scan"
                class={[
                  "btn-line w-full justify-center text-xs",
                  (!is_nil(@running_security_scan) || @scanning) && "opacity-50 cursor-not-allowed"
                ]}
                disabled={!is_nil(@running_security_scan) || @scanning}
              >
                <.icon name="hero-bolt" class="w-3.5 h-3.5" /> Run Security Scan
              </button>
            <% end %>
          <% end %>
        </div>

        <div id="security-scan-card">
          <%= cond do %>
            <% @running_security_scan -> %>
              <div class="border border-neutral-100 rounded-lg p-4 bg-neutral-50/30">
                <div class="flex items-center justify-between mb-4">
                  <span class="text-xs font-medium text-neutral-900">Security Scan</span>
                  <span class="text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded-sm bg-yellow-50 text-yellow-600">
                    running
                  </span>
                </div>
                <div class="space-y-3 py-2">
                  <div class="flex justify-between text-[10px] text-neutral-500 font-light">
                    <span>Phase: {scan_phase_label(@running_security_scan.progress)}</span>
                    <span>{@running_security_scan.progress}%</span>
                  </div>
                  <div class="w-full h-1.5 bg-neutral-200 rounded-full overflow-hidden">
                    <div
                      class="h-full bg-blue-500 transition-all duration-1000 ease-in-out"
                      style={"width: #{@running_security_scan.progress}%"}
                    >
                    </div>
                  </div>
                </div>
              </div>
            <% @latest_security_scan -> %>
              <% findings =
                if Ecto.assoc_loaded?(@latest_security_scan.findings),
                  do: @latest_security_scan.findings,
                  else: [] %>
              <div class="border border-neutral-100 rounded-lg p-4 bg-neutral-50/30">
                <div class="flex items-center justify-between mb-4">
                  <div class="flex items-center gap-2">
                    <span class="text-xs font-medium text-neutral-900">Security Scan</span>
                    <span class="text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded-sm bg-green-50 text-green-600">
                      completed
                    </span>
                  </div>
                  <div class="flex items-center gap-2">
                    <span class="text-[10px] text-neutral-400 font-light">
                      {Calendar.strftime(
                        @latest_security_scan.completed_at || @latest_security_scan.inserted_at,
                        "%Y-%m-%d %H:%M"
                      )}
                    </span>
                    <%= if @current_scope && @current_scope.user.role == :admin do %>
                      <button
                        type="button"
                        phx-click="delete_scan"
                        phx-value-id={@latest_security_scan.id}
                        phx-target={@myself}
                        data-confirm="Delete this scan and its findings?"
                        class="text-neutral-300 hover:text-red-500 transition-colors"
                        title="Delete scan"
                      >
                        <.icon name="hero-trash" class="w-3.5 h-3.5" />
                      </button>
                    <% end %>
                  </div>
                </div>

                <%= if findings != [] do %>
                  <div class="space-y-2">
                    <div class="grid grid-cols-2 gap-2 text-sm">
                      <% critical_count = findings |> Enum.count(&(&1.severity == "critical")) %>
                      <% high_count = findings |> Enum.count(&(&1.severity == "high")) %>
                      <% medium_count = findings |> Enum.count(&(&1.severity == "medium")) %>
                      <% low_count = findings |> Enum.count(&(&1.severity == "low")) %>
                      <div class="flex items-center gap-2">
                        <span class="w-2 h-2 rounded-full bg-red-500"></span>
                        <span class="text-xs font-light text-neutral-600">
                          Critical: <span class="font-medium text-neutral-900">{critical_count}</span>
                        </span>
                      </div>
                      <div class="flex items-center gap-2">
                        <span class="w-2 h-2 rounded-full bg-orange-500"></span>
                        <span class="text-xs font-light text-neutral-600">
                          High: <span class="font-medium text-neutral-900">{high_count}</span>
                        </span>
                      </div>
                      <div class="flex items-center gap-2">
                        <span class="w-2 h-2 rounded-full bg-yellow-500"></span>
                        <span class="text-xs font-light text-neutral-600">
                          Medium: <span class="font-medium text-neutral-900">{medium_count}</span>
                        </span>
                      </div>
                      <div class="flex items-center gap-2">
                        <span class="w-2 h-2 rounded-full bg-blue-500"></span>
                        <span class="text-xs font-light text-neutral-600">
                          Low: <span class="font-medium text-neutral-900">{low_count}</span>
                        </span>
                      </div>
                    </div>
                    <button
                      phx-click="toggle_findings_modal"
                      phx-target={@myself}
                      class="btn-line w-full justify-center text-xs mt-3"
                    >
                      <.icon name="hero-document-magnifying-glass" class="w-3.5 h-3.5" />
                      View findings
                    </button>
                  </div>
                <% else %>
                  <div class="flex flex-col items-center justify-center py-6 opacity-40">
                    <.icon name="hero-check-badge" class="w-8 h-8 text-green-500 mb-1" />
                    <p class="text-xs font-light">No vulnerabilities found</p>
                  </div>
                <% end %>
              </div>
            <% @latest_failed_security_scan -> %>
              <div class="p-3 bg-red-50 border border-red-100 rounded-md text-red-700 text-[11px] font-light">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <p class="font-semibold mb-1">Last scan failed</p>
                    <p class="leading-relaxed text-red-600">
                      {@latest_failed_security_scan.error_message}
                    </p>
                  </div>
                  <%= if @current_scope && @current_scope.user.role == :admin do %>
                    <button
                      type="button"
                      phx-click="delete_scan"
                      phx-value-id={@latest_failed_security_scan.id}
                      phx-target={@myself}
                      data-confirm="Delete this failed scan?"
                      class="shrink-0 inline-flex items-center gap-1 text-[10px] uppercase tracking-wide text-red-500 hover:text-red-700 transition-colors"
                      aria-label="Delete failed scan"
                    >
                      <.icon name="hero-trash" class="w-3 h-3" /> Delete
                    </button>
                  <% end %>
                </div>
              </div>
            <% true -> %>
              <div class="flex flex-col items-center justify-center py-8 text-neutral-400">
                <.icon name="hero-shield-check" class="w-8 h-8 mb-2" />
                <p class="text-xs font-light">No security scan yet</p>
              </div>
          <% end %>
        </div>
      </div>

      <%!-- Findings modal --%>
      <%= if @show_findings_modal && @latest_security_scan do %>
        <% findings =
          if Ecto.assoc_loaded?(@latest_security_scan.findings),
            do: @latest_security_scan.findings,
            else: [] %>
        <div class="fixed inset-0 bg-black/50 z-50 flex items-center justify-center p-4">
          <div class="bg-white rounded-lg max-w-3xl w-full max-h-[80vh] overflow-hidden flex flex-col">
            <div class="flex items-center justify-between p-6 border-b border-neutral-200">
              <h2 class="text-lg font-light">Security Findings</h2>
              <button
                phx-click="toggle_findings_modal"
                phx-target={@myself}
                class="text-neutral-400 hover:text-neutral-900 transition-colors"
                aria-label="Close"
              >
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>
            <div class="overflow-y-auto flex-1 p-6">
              <%= if findings != [] do %>
                <div class="space-y-3">
                  <%= for finding <- Enum.sort_by(findings, & &1.severity) do %>
                    <div class="border border-neutral-100 rounded-lg p-4 hover:border-neutral-200 transition-colors">
                      <div class="flex items-start gap-3">
                        <span class={[
                          "shrink-0 w-3 h-3 rounded-full mt-1",
                          finding.severity == "critical" && "bg-red-500",
                          finding.severity == "high" && "bg-orange-500",
                          finding.severity == "medium" && "bg-yellow-500",
                          finding.severity == "low" && "bg-blue-500",
                          finding.severity not in ["critical", "high", "medium", "low"] &&
                            "bg-neutral-300"
                        ]}>
                        </span>
                        <div class="flex-1 min-w-0">
                          <div class="flex items-center gap-2">
                            <p class="font-medium text-neutral-900">{finding.title}</p>
                            <span class={[
                              "text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded-sm font-medium",
                              finding.severity == "critical" && "bg-red-50 text-red-600",
                              finding.severity == "high" && "bg-orange-50 text-orange-600",
                              finding.severity == "medium" && "bg-yellow-50 text-yellow-600",
                              finding.severity == "low" && "bg-blue-50 text-blue-600"
                            ]}>
                              {finding.severity}
                            </span>
                          </div>
                          <p class="text-sm text-neutral-500 mt-1 font-light break-all">
                            {finding.target}
                          </p>
                          <%= if finding.detail && is_map(finding.detail) do %>
                            <div class="mt-2 text-xs text-neutral-400 space-y-0.5">
                              <%= for {key, value} <- Map.to_list(finding.detail) |> Enum.take(3) do %>
                                <% display_value =
                                  if is_binary(value),
                                    do: String.slice(value, 0, 60),
                                    else: inspect(value) %>
                                <p><span class="font-medium">{key}:</span> {display_value}</p>
                              <% end %>
                            </div>
                          <% end %>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <div class="flex flex-col items-center justify-center py-8 text-neutral-400">
                  <.icon name="hero-check-badge" class="w-8 h-8 mb-2" />
                  <p class="text-sm font-light">No findings</p>
                </div>
              <% end %>
            </div>
            <div class="flex items-center justify-end gap-2 p-6 border-t border-neutral-200">
              <button
                phx-click="toggle_findings_modal"
                phx-target={@myself}
                class="btn-line text-xs"
              >
                Close
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_findings_modal", _, socket) do
    {:noreply, assign(socket, :show_findings_modal, !socket.assigns.show_findings_modal)}
  end

  @impl true
  def handle_event("run_security_scan", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role not in [:admin, :editor] do
    {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
  end

  def handle_event("run_security_scan", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()
    user_id = socket.assigns.current_scope.user.id

    if socket.assigns.running_security_scan do
      {:noreply, put_flash(socket, :error, "A security scan is already in progress.")}
    else
      case SecurityRunner.run_security_scan(domain_id, liveview_pid, user_id) do
        {:ok, _scan} ->
          send(liveview_pid, :refresh_security_scans)
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    end
  end

  @impl true
  def handle_event("clear_scans", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role != :admin do
    {:noreply, put_flash(socket, :error, "Admin access required.")}
  end

  def handle_event("clear_scans", _, socket) do
    domain_id = socket.assigns.domain.id
    SecurityScans.clear_running_scans(domain_id)

    send(self(), :refresh_security_scans)

    {:noreply, put_flash(socket, :info, "Running scans cleared.")}
  end

  @impl true
  def handle_event("delete_scan", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or scope.user.role != :admin do
    {:noreply, put_flash(socket, :error, "Admin access required.")}
  end

  def handle_event("delete_scan", %{"id" => scan_id}, socket) do
    scan_id = String.to_integer(scan_id)

    case Repo.get(Ravner.SecurityScans.SecurityScan, scan_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Scan not found.")}

      scan ->
        SecurityScans.delete_scan(scan)
        send(self(), :refresh_security_scans)
        {:noreply, socket}
    end
  end

  defp scan_phase_label(progress) when is_integer(progress) do
    cond do
      progress < 30 -> "Tech detection"
      progress < 55 -> "Port discovery"
      progress < 90 -> "Vulnerability scan"
      true -> "Finalizing"
    end
  end

  defp scan_phase_label(_), do: "Starting"
end
