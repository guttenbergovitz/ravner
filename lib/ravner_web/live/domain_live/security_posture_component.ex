defmodule RavnerWeb.DomainLive.SecurityPostureComponent do
  @moduledoc """
  LiveComponent encapsulating the Security Posture view and manual triggers.
  """
  use RavnerWeb, :live_component

  alias Ravner.Domains.Domain
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
      <%= if Domain.hide_scoring?(@domain) do %>
        <div class="card-line">
          <h2 class="text-sm font-normal tracking-wide uppercase mb-4">Security Posture</h2>
          <div class="py-6 text-center border border-dashed border-neutral-200 rounded">
            <.icon name="hero-shield-check" class="w-6 h-6 text-neutral-300 mx-auto mb-2" />
            <p class="text-xs font-light text-neutral-400">
              <%= case @domain.lifecycle_state do %>
                <% :placeholder -> %>
                  Security scanning not applicable for placeholder domains
                <% :redirect_internal -> %>
                  Security inherited from redirect target
                <% :redirect_external -> %>
                  Security scanning not applicable — redirects to external domain
                <% _ -> %>
                  Security scanning not available
              <% end %>
            </p>
            <%= if @domain.redirect_target_url do %>
              <p class="text-[10px] text-neutral-400 mt-2 font-mono">
                →
                <%= if @domain.lifecycle_state == :redirect_internal && @domain.redirect_target_domain_id do %>
                  <.link
                    navigate={~p"/domains/#{@domain.redirect_target_domain_id}"}
                    class="text-blue-500 hover:underline"
                  >
                    {@domain.redirect_target_url}
                  </.link>
                <% else %>
                  {@domain.redirect_target_url}
                <% end %>
              </p>
            <% end %>
          </div>
        </div>
      <% else %>
        <div class="card-line">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-sm font-normal tracking-wide uppercase">Security Posture</h2>
            <%= if @running_security_scan && @current_scope && @current_scope.admin? do %>
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
            <%= cond do %>
              <% @domain.technical_status == :redirect -> %>
                <p class="text-[10px] text-neutral-400 italic text-center py-1">
                  Security scan unavailable — domain redirects externally
                </p>
              <% not Ravner.Domains.Domain.scannable?(@domain) -> %>
                <p class="text-[10px] text-neutral-400 italic text-center py-1">
                  Security scan unavailable — domain is {@domain.lifecycle_state
                  |> Atom.to_string()
                  |> String.replace("_", " ")}
                </p>
              <% true -> %>
                <%= if Ravner.Accounts.ScopeResolver.can_scan_domain?(@current_scope, @domain) do %>
                  <button
                    phx-click="run_security_scan"
                    phx-target={@myself}
                    id="run-security-scan"
                    class={[
                      "btn-line w-full justify-center text-xs",
                      (!is_nil(@running_security_scan) || @scanning) &&
                        "opacity-50 cursor-not-allowed"
                    ]}
                    disabled={!is_nil(@running_security_scan) || @scanning}
                  >
                    <.icon name="hero-bolt" class="w-3.5 h-3.5" /> Run Security Scan
                  </button>
                  <button
                    phx-click="run_breach_scan"
                    phx-target={@myself}
                    id="run-breach-scan"
                    title="Check dark web infostealer logs and active compromised credentials via Hudson Rock OSINT"
                    class={[
                      "btn-line w-full justify-center text-xs text-neutral-600 hover:text-red-600",
                      (!is_nil(@running_security_scan) || @scanning) &&
                        "opacity-50 cursor-not-allowed"
                    ]}
                    disabled={!is_nil(@running_security_scan) || @scanning}
                  >
                    <.icon name="hero-finger-print" class="w-3.5 h-3.5" /> Check Dark Web Leaks
                  </button>
                <% end %>
            <% end %>
          </div>

          <div id="security-scan-card" class="space-y-4">
            <%!-- Running scan progress --%>
            <%= if @running_security_scan do %>
              <div class="border border-neutral-100 rounded-lg p-4 bg-neutral-50/30">
                <div class="flex items-center justify-between mb-4">
                  <span class="text-xs font-medium text-neutral-900">
                    {scan_title(@running_security_scan)}
                  </span>
                  <span class="text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded-sm bg-yellow-50 text-yellow-600 font-medium">
                    running
                  </span>
                </div>
                <div class="space-y-3 py-2">
                  <div class="flex justify-between text-[10px] text-neutral-500 font-light">
                    <span>
                      Phase: {scan_phase_label(
                        @running_security_scan.progress,
                        @running_security_scan.tool
                      )}
                    </span>
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
            <% end %>

            <%!-- Vulnerability & Exposure Posture --%>
            <%= if @latest_security_scan do %>
              <% findings =
                if Ecto.assoc_loaded?(@latest_security_scan.findings),
                  do: @latest_security_scan.findings,
                  else: [] %>
              <div class="border border-neutral-100 rounded-lg p-4 bg-neutral-50/30">
                <div class="flex items-center justify-between mb-3">
                  <div class="flex items-center gap-2">
                    <span class="text-xs font-medium text-neutral-900">
                      {scan_title(@latest_security_scan)}
                    </span>
                    <span class="text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded-sm bg-green-50 text-green-600 font-medium">
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
                    <%= if @current_scope && @current_scope.admin? do %>
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

                <%= if @latest_security_scan.summary do %>
                  <div class="mb-3 text-xs text-neutral-600 font-light bg-neutral-100/60 px-2.5 py-1.5 rounded truncate">
                    {@latest_security_scan.summary}
                  </div>
                <% end %>

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
                  </div>
                <% else %>
                  <div class="flex items-center gap-2 py-2 text-green-600 text-xs font-light">
                    <.icon name="hero-check-circle" class="w-4 h-4" />
                    <span>No vulnerabilities or exposures detected</span>
                  </div>
                <% end %>
              </div>
            <% else %>
              <%= if is_nil(@running_security_scan) do %>
                <div class="border border-dashed border-neutral-200 rounded-lg p-4 text-center">
                  <p class="text-xs font-light text-neutral-400">No vulnerability scan yet</p>
                </div>
              <% end %>
            <% end %>

            <%!-- Dark Web Breach Intelligence Posture --%>
            <%= if assigns[:latest_breach_scan] && @latest_breach_scan do %>
              <div class="border border-neutral-100 rounded-lg p-4 bg-neutral-50/30">
                <div class="flex items-center justify-between mb-2">
                  <div class="flex items-center gap-2">
                    <span class="text-xs font-medium text-neutral-900">
                      Dark Web Intelligence
                    </span>
                    <span class="text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded-sm bg-green-50 text-green-600 font-medium">
                      completed
                    </span>
                  </div>
                  <div class="flex items-center gap-2">
                    <span class="text-[10px] text-neutral-400 font-light">
                      {Calendar.strftime(
                        @latest_breach_scan.completed_at || @latest_breach_scan.inserted_at,
                        "%Y-%m-%d %H:%M"
                      )}
                    </span>
                    <%= if @current_scope && @current_scope.admin? do %>
                      <button
                        type="button"
                        phx-click="delete_scan"
                        phx-value-id={@latest_breach_scan.id}
                        phx-target={@myself}
                        data-confirm="Delete this dark web breach scan?"
                        class="text-neutral-300 hover:text-red-500 transition-colors"
                        title="Delete scan"
                      >
                        <.icon name="hero-trash" class="w-3.5 h-3.5" />
                      </button>
                    <% end %>
                  </div>
                </div>

                <%= if @latest_breach_scan.summary do %>
                  <div class="text-xs text-neutral-600 font-light flex items-center gap-1.5 bg-neutral-100/60 px-2.5 py-1.5 rounded">
                    <%= if String.contains?(@latest_breach_scan.summary, "Hot") or String.contains?(@latest_breach_scan.summary, "🔥") do %>
                      <.icon name="hero-fire" class="w-3.5 h-3.5 text-red-500 shrink-0" />
                    <% end %>
                    <span class="truncate">{@latest_breach_scan.summary}</span>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%!-- Failed Scan Notice --%>
            <%= if @latest_failed_security_scan && is_nil(@latest_security_scan) && is_nil(assigns[:latest_breach_scan]) do %>
              <div class="p-3 bg-red-50 border border-red-100 rounded-md text-red-700 text-[11px] font-light">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <p class="font-semibold mb-1">Last scan failed</p>
                    <p class="leading-relaxed text-red-600">
                      {@latest_failed_security_scan.error_message}
                    </p>
                  </div>
                  <%= if @current_scope && @current_scope.admin? do %>
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
            <% end %>

            <%!-- Primary CTA: Dedicated Report Page --%>
            <div class="pt-1">
              <.link
                navigate={~p"/domains/#{@domain.id}/security"}
                id="view-full-security-report-btn"
                class="btn-line w-full justify-center text-xs font-normal inline-flex items-center gap-1.5 py-2 hover:border-neutral-900 whitespace-nowrap"
              >
                <.icon name="hero-shield-check" class="w-4 h-4 text-blue-600 shrink-0" />
                <span>View Security Report</span>
                <.icon name="hero-arrow-right" class="w-3 h-3 text-neutral-400 shrink-0" />
              </.link>
            </div>
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
                              <%= if finding.detail && (finding.detail["osv_id"] || (finding.detail["cve"] && (String.starts_with?(finding.detail["cve"], "CVE-") || String.starts_with?(finding.detail["cve"], "GHSA-") || String.starts_with?(finding.detail["cve"], "BIT-")))) do %>
                                <% primary_url =
                                  if finding.detail["cve"] &&
                                       String.starts_with?(finding.detail["cve"], "CVE-") do
                                    "https://nvd.nist.gov/vuln/detail/#{finding.detail["cve"]}"
                                  else
                                    "https://osv.dev/vulnerability/#{finding.detail["osv_id"] || finding.detail["cve"]}"
                                  end %>
                                <a
                                  href={primary_url}
                                  target="_blank"
                                  rel="noopener noreferrer"
                                  class="font-medium text-neutral-900 hover:text-blue-600 hover:underline inline-flex items-center gap-1.5"
                                  title="Open advisory in new tab"
                                >
                                  {finding.title}
                                  <.icon
                                    name="hero-arrow-top-right-on-square"
                                    class="w-3.5 h-3.5 text-neutral-400 shrink-0"
                                  />
                                </a>
                              <% else %>
                                <p class="font-medium text-neutral-900">{finding.title}</p>
                              <% end %>
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
                              <% detail = finding.detail %>
                              <div class="mt-3 text-xs space-y-2">
                                <%= if detail["description"] || detail["summary"] do %>
                                  <p class="text-neutral-600 leading-relaxed font-light">
                                    {detail["description"] || detail["summary"]}
                                  </p>
                                <% end %>

                                <%= if detail["heat_label"] do %>
                                  <div class="mt-2 flex items-center gap-1.5">
                                    <span class={[
                                      "inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded border",
                                      detail["heat"] == "hot" &&
                                        "bg-red-50 text-red-700 border-red-200",
                                      detail["heat"] == "recent" &&
                                        "bg-orange-50 text-orange-700 border-orange-200",
                                      detail["heat"] == "historical" &&
                                        "bg-neutral-100 text-neutral-700 border-neutral-200",
                                      detail["heat"] == "clean" &&
                                        "bg-green-50 text-green-700 border-green-200"
                                    ]}>
                                      <%= if detail["heat"] == "hot" do %>
                                        <.icon name="hero-fire" class="w-3.5 h-3.5 text-red-600" />
                                      <% end %>
                                      {detail["heat_label"]}
                                    </span>
                                  </div>
                                <% end %>

                                <%= if detail["stealer_families"] && detail["stealer_families"] != [] do %>
                                  <div class="flex flex-wrap items-center gap-1.5 mt-2">
                                    <span class="text-neutral-400 font-medium text-[11px]">
                                      Malware Families:
                                    </span>
                                    <%= for family <- detail["stealer_families"] do %>
                                      <span class="bg-red-50 text-red-700 border border-red-100 px-1.5 py-0.5 rounded text-[11px] font-mono">
                                        {family}
                                      </span>
                                    <% end %>
                                  </div>
                                <% end %>

                                <%= if detail["targeted_urls"] && detail["targeted_urls"] != [] do %>
                                  <div class="mt-2 pt-2 border-t border-neutral-100">
                                    <span class="text-neutral-400 font-medium block mb-1 text-[11px]">
                                      Compromised Corporate Portals:
                                    </span>
                                    <div class="flex flex-col gap-1">
                                      <%= for url <- detail["targeted_urls"] do %>
                                        <span class="font-mono text-[11px] text-neutral-700 truncate">
                                          {url}
                                        </span>
                                      <% end %>
                                    </div>
                                  </div>
                                <% end %>

                                <%= if detail["aliases"] && detail["aliases"] != [] do %>
                                  <div class="flex flex-wrap items-center gap-1.5">
                                    <span class="text-neutral-400 font-medium">Aliases:</span>
                                    <%= for alias_id <- detail["aliases"] do %>
                                      <span class="bg-neutral-100 text-neutral-600 px-1.5 py-0.5 rounded text-[11px] font-mono">
                                        {alias_id}
                                      </span>
                                    <% end %>
                                  </div>
                                <% end %>

                                <%= if detail["references"] && detail["references"] != [] do %>
                                  <div class="mt-2 pt-2 border-t border-neutral-100">
                                    <span class="text-neutral-400 font-medium block mb-1">
                                      References & Advisories:
                                    </span>
                                    <div class="flex flex-col gap-1">
                                      <%= for ref <- detail["references"] do %>
                                        <a
                                          href={ref}
                                          target="_blank"
                                          rel="noopener noreferrer"
                                          class="text-blue-600 hover:text-blue-800 hover:underline truncate flex items-center gap-1 font-mono text-[11px]"
                                        >
                                          <.icon
                                            name="hero-arrow-top-right-on-square"
                                            class="w-3 h-3 shrink-0"
                                          />
                                          {ref}
                                        </a>
                                      <% end %>
                                    </div>
                                  </div>
                                <% end %>

                                <%= if !detail["description"] && !detail["summary"] && (!detail["references"] || detail["references"] == []) do %>
                                  <div class="text-neutral-400 space-y-0.5">
                                    <%= for {key, value} <- Map.to_list(detail) |> Enum.take(3) do %>
                                      <% display_value =
                                        if is_binary(value),
                                          do: String.slice(value, 0, 60),
                                          else: inspect(value) %>
                                      <p><span class="font-medium">{key}:</span> {display_value}</p>
                                    <% end %>
                                  </div>
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
      <% end %>
    </div>
    """
  end

  defp notify_flash(socket, kind, msg) do
    send(self(), {:put_flash, kind, msg})
    put_flash(socket, kind, msg)
  end

  @impl true
  def handle_event("toggle_findings_modal", _, socket) do
    {:noreply, assign(socket, :show_findings_modal, !socket.assigns.show_findings_modal)}
  end

  @impl true
  def handle_event("run_security_scan", params, socket) do
    domain = socket.assigns.domain

    cond do
      not Ravner.Accounts.ScopeResolver.can_scan_domain?(
        socket.assigns[:current_scope],
        domain
      ) ->
        {:noreply,
         notify_flash(socket, :error, "You don't have permission to perform this action.")}

      not Ravner.Domains.Domain.scannable?(domain) ->
        {:noreply,
         notify_flash(
           socket,
           :error,
           "Security scanning is disabled for #{domain.lifecycle_state} domains."
         )}

      socket.assigns.running_security_scan ->
        {:noreply, notify_flash(socket, :error, "A security scan is already in progress.")}

      true ->
        liveview_pid = self()
        user_id = socket.assigns.current_scope.user.id

        mode =
          case params["mode"] do
            "heavy" -> :heavy
            "light" -> :light
            _ -> nil
          end

        case SecurityRunner.run_security_scan(domain.id, liveview_pid, user_id, mode) do
          {:ok, _scan} ->
            send(liveview_pid, :refresh_security_scans)
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, notify_flash(socket, :error, reason)}
        end
    end
  end

  @impl true
  def handle_event("run_breach_scan", _params, socket) do
    domain = socket.assigns.domain

    cond do
      not Ravner.Accounts.ScopeResolver.can_scan_domain?(
        socket.assigns[:current_scope],
        domain
      ) ->
        {:noreply,
         notify_flash(socket, :error, "You don't have permission to perform this action.")}

      not Ravner.Domains.Domain.scannable?(domain) ->
        {:noreply,
         notify_flash(
           socket,
           :error,
           "Security scanning is disabled for #{domain.lifecycle_state} domains."
         )}

      socket.assigns.running_security_scan ->
        {:noreply, notify_flash(socket, :error, "A security scan is already in progress.")}

      true ->
        liveview_pid = self()
        user_id = socket.assigns.current_scope.user.id

        case SecurityRunner.run_breach_scan(domain.id, liveview_pid, user_id) do
          {:ok, _scan} ->
            send(liveview_pid, :refresh_security_scans)
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, notify_flash(socket, :error, reason)}
        end
    end
  end

  @impl true
  def handle_event("clear_scans", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or not scope.admin? do
    {:noreply, notify_flash(socket, :error, "Admin access required.")}
  end

  @impl true
  def handle_event("clear_scans", _, socket) do
    domain_id = socket.assigns.domain.id
    SecurityScans.clear_running_scans(domain_id)

    send(self(), :refresh_security_scans)

    {:noreply, notify_flash(socket, :info, "Running scans cleared.")}
  end

  @impl true
  def handle_event("delete_scan", _, %{assigns: %{current_scope: scope}} = socket)
      when is_nil(scope) or not scope.admin? do
    {:noreply, notify_flash(socket, :error, "Admin access required.")}
  end

  @impl true
  def handle_event("delete_scan", %{"id" => scan_id}, socket) do
    scan_id = String.to_integer(scan_id)

    case Repo.get(Ravner.SecurityScans.SecurityScan, scan_id) do
      nil ->
        {:noreply, notify_flash(socket, :error, "Scan not found.")}

      scan ->
        SecurityScans.delete_scan(scan)
        send(self(), :refresh_security_scans)
        {:noreply, socket}
    end
  end

  defp scan_title(%{tool: "breach_lookup"}), do: "Dark Web & Stealer Intelligence"
  defp scan_title(%{tool: "light_scan"}), do: "Security Scan (Light)"
  defp scan_title(%{tool: "security_scan"}), do: "Security Scan (Deep)"
  defp scan_title(_), do: "Security Scan"

  defp scan_phase_label(progress, "breach_lookup") when is_integer(progress) do
    cond do
      progress < 40 -> "Contacting intelligence feed"
      progress < 75 -> "Analyzing stealer logs & recency"
      true -> "Finalizing"
    end
  end

  defp scan_phase_label(progress, _) when is_integer(progress) do
    cond do
      progress < 30 -> "HTTP probe"
      progress < 55 -> "Tech fingerprinting"
      progress < 85 -> "Vulnerability & CVE scan"
      true -> "Finalizing"
    end
  end

  defp scan_phase_label(_, _), do: "Starting"
end
