defmodule RavnerWeb.DomainLive.ShowTechnicalTab do
  @moduledoc """
  Functional components for the Technical Overview tab of `RavnerWeb.DomainLive.Show`.
  """
  use RavnerWeb, :html

  import RavnerWeb.DomainComponents

  attr :domain, :map, required: true
  attr :domain_class, :any, required: true
  attr :current_scope, :map, default: nil
  attr :can_manage?, :boolean, required: true
  attr :can_scan?, :boolean, required: true
  attr :escalation_chain, :map, required: true
  attr :primary_repo, :map, default: nil
  attr :domain_repos, :list, default: []
  attr :project_repos, :list, default: []

  def domain_technical_tab(assigns) do
    ~H"""
    <div class="card-line" id="technical-details-card">
      <div class="flex items-center justify-between mb-6">
        <h2 class="text-sm font-normal tracking-wide uppercase">Technical Summary</h2>
        <.link
          patch={~p"/domains/#{@domain.id}?tab=governance"}
          class="text-xs text-neutral-500 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-100 transition-colors inline-flex items-center gap-1 font-light"
        >
          Manage Ownership <.icon name="hero-arrow-right" class="w-3 h-3" />
        </.link>
      </div>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-6 text-sm">
        <div>
          <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
            URL
          </span>
          <span :if={@domain.url} class="font-light break-all">{@domain.url}</span>
          <span :if={!@domain.url} class="text-neutral-400 font-light">—</span>
        </div>
        <div>
          <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
            HTTP status
          </span>
          <.http_status class={@domain_class} />
        </div>
        <div>
          <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
            Technical
          </span>
          <.technical_status_indicator status={@domain.technical_status} />
        </div>
        <div>
          <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
            Lifecycle
          </span>
          <.live_component
            module={RavnerWeb.DomainLive.LifecycleDropdown}
            id="lifecycle-dropdown"
            domain={@domain}
            current_scope={@current_scope}
            can_manage?={@can_manage?}
          />
        </div>
      </div>

      <%!-- Clean 1-line Ownership & Escalation summary --%>
      <div class="mt-6 pt-4 border-t border-neutral-100 dark:border-neutral-800 flex flex-wrap items-center gap-y-2 gap-x-6 text-xs text-neutral-600 dark:text-neutral-400">
        <div class="flex items-center gap-1.5">
          <span class="uppercase tracking-wider text-[10px] text-neutral-400">
            Brand:
          </span>
          <%= if @escalation_chain.level_3_brand.brand do %>
            <.link
              navigate={~p"/ownership/brands/#{@escalation_chain.level_3_brand.brand.id}"}
              class="font-medium text-neutral-800 dark:text-neutral-200 hover:underline"
            >
              {@escalation_chain.level_3_brand.brand.display_name ||
                @escalation_chain.level_3_brand.brand.name}
            </.link>
          <% else %>
            <span class="text-neutral-400 italic font-light">None</span>
          <% end %>
        </div>

        <div class="flex items-center gap-1.5">
          <span class="uppercase tracking-wider text-[10px] text-neutral-400">
            Organization:
          </span>
          <%= if @escalation_chain.level_2_organization.organization do %>
            <.link
              navigate={
                ~p"/ownership/organizations/#{@escalation_chain.level_2_organization.organization.id}"
              }
              class="font-medium text-neutral-800 dark:text-neutral-200 hover:underline"
            >
              {@escalation_chain.level_2_organization.organization.display_name ||
                @escalation_chain.level_2_organization.organization.name}
            </.link>
          <% else %>
            <span class="text-neutral-400 italic font-light">None</span>
          <% end %>
        </div>

        <div class="flex items-center gap-1.5">
          <span class="uppercase tracking-wider text-[10px] text-neutral-400">
            Project:
          </span>
          <%= if @escalation_chain.level_1_project.project do %>
            <span class="font-medium text-neutral-800 dark:text-neutral-200">
              {@escalation_chain.level_1_project.project.name}
            </span>
          <% else %>
            <span class="text-neutral-400 italic font-light">None</span>
          <% end %>
        </div>

        <div class="flex items-center gap-1.5">
          <span class="uppercase tracking-wider text-[10px] text-neutral-400">Repo:</span>
          <%= if @primary_repo do %>
            <a
              href={@primary_repo.url}
              target="_blank"
              rel="noopener noreferrer"
              class="text-neutral-800 dark:text-neutral-200 hover:underline inline-flex items-center gap-1"
            >
              <span class="truncate max-w-[180px]">
                {@primary_repo.external_id || @primary_repo.url}
              </span>
              <.icon
                name="hero-arrow-top-right-on-square"
                class="w-3 h-3 text-neutral-400"
              />
            </a>
            <%= if length(@domain_repos) > 1 do %>
              <span class="text-[10px] text-neutral-400 font-normal">
                (+{length(@domain_repos) - 1})
              </span>
            <% end %>
          <% else %>
            <%= if @domain.repository_url do %>
              <a
                href={@domain.repository_url}
                target="_blank"
                rel="noopener noreferrer"
                class="text-neutral-800 dark:text-neutral-200 hover:underline inline-flex items-center gap-1"
              >
                <span class="truncate max-w-[180px]">{@domain.repository_url}</span>
                <.icon
                  name="hero-arrow-top-right-on-square"
                  class="w-3 h-3 text-neutral-400"
                />
              </a>
            <% else %>
              <%= if @can_manage? do %>
                <button
                  type="button"
                  phx-click="open_link_repo"
                  class="text-[11px] text-neutral-500 hover:text-neutral-900 underline dark:text-neutral-400 dark:hover:text-neutral-200"
                >
                  + Link
                </button>
              <% else %>
                <span class="text-neutral-400 italic font-light">—</span>
              <% end %>
            <% end %>
          <% end %>
        </div>

        <%!-- Application Workload --%>
        <div class="flex items-center gap-1.5">
          <span class="uppercase tracking-wider text-[10px] text-neutral-400">App:</span>
          <%= if @domain.application do %>
            <.link
              navigate={
                if @domain.project_id,
                  do: ~p"/ownership/projects/#{@domain.project_id}?tab=landscape",
                  else: ~p"/ownership/landscape"
              }
              class="font-medium text-neutral-800 dark:text-neutral-200 hover:underline inline-flex items-center gap-1"
              title={"Criticality: #{@domain.application.criticality}"}
            >
              <span class="text-[9px] uppercase tracking-wide px-1 rounded bg-amber-50 text-amber-700 border border-amber-200 font-mono dark:bg-amber-950 dark:text-amber-300 dark:border-amber-800">
                {@domain.application.app_type}
              </span>
              <span>{@domain.application.name}</span>
            </.link>
          <% else %>
            <span class="text-neutral-400 italic font-light">None</span>
          <% end %>
        </div>

        <%!-- Registrar --%>
        <div class="flex items-center gap-1.5">
          <span class="uppercase tracking-wider text-[10px] text-neutral-400">
            Registrar:
          </span>
          <%= if @domain.registrar do %>
            <span class="font-medium text-neutral-800 dark:text-neutral-200">
              {@domain.registrar.name}
            </span>
          <% else %>
            <span class="text-neutral-600 dark:text-neutral-400">
              {@domain.domain_registrar || "—"}
            </span>
          <% end %>
        </div>
      </div>
    </div>

    <%!-- Executive Cyber Risk & Posture Score Card --%>
    <div class="card-line" id="cyber-risk-posture-card">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h2 class="text-sm font-normal tracking-wide uppercase">
            Cyber Risk & Executive Posture
          </h2>
          <p class="text-xs font-light text-neutral-400 mt-0.5">
            Unified risk index evaluating domain web & network scans (CVEs, exposures, TLS, headers, ports, uptime) and linked VCS repositories.
          </p>
        </div>
        <%= unless Ravner.Domains.Domain.hide_scoring?(@domain) do %>
          <button
            type="button"
            phx-click="recalculate_risk"
            id="recalculate-risk-btn"
            class="btn-secondary text-xs inline-flex items-center gap-1.5"
            title="Recalculate deterministic cyber risk score across domain and attached repositories"
          >
            <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> Recalculate Posture
          </button>
        <% end %>
      </div>

      <%= if Ravner.Domains.Domain.hide_scoring?(@domain) do %>
        <div class="flex items-center gap-3 p-4 rounded-lg bg-neutral-100 dark:bg-neutral-800/50 border border-neutral-200 dark:border-neutral-700">
          <.icon name="hero-minus-circle" class="w-5 h-5 text-neutral-400 shrink-0" />
          <div>
            <div class="text-sm font-medium text-neutral-600 dark:text-neutral-300">
              Risk Scoring Not Applicable
            </div>
            <div class="text-xs text-neutral-500 dark:text-neutral-400 mt-0.5">
              <%= if Ravner.Domains.Domain.redirect?(@domain) do %>
                Redirect domains inherit security posture from their target.
              <% else %>
                Placeholder domains are not scanned. Change lifecycle state to enable scoring.
              <% end %>
            </div>
          </div>
        </div>
      <% else %>
        <% meta = @domain.domain_metadata || %Ravner.Domains.DomainMetadata{} %>
        <% grade = meta.risk_grade || "N/A" %>
        <% score = meta.risk_score %>
        <% deductions = meta.risk_deductions || %{} %>
        <% drivers =
          if meta.risk_drivers != [],
            do: meta.risk_drivers,
            else:
              if(is_nil(score),
                do: [
                  "No scans or probes have been recorded yet — cyber risk scoring pending initial scan."
                ],
                else: []
              ) %>

        <div class="grid grid-cols-1 lg:grid-cols-12 gap-6 items-center border border-neutral-100 dark:border-neutral-800 p-5 rounded-lg bg-neutral-50/50 dark:bg-neutral-900/50 mb-6">
          <%!-- Executive Grade & Score Gauge --%>
          <div class="lg:col-span-4 flex items-center gap-4 lg:border-r border-neutral-200 dark:border-neutral-800 lg:pr-6 min-w-0">
            <div class={[
              "w-14 h-14 sm:w-16 sm:h-16 rounded-xl flex items-center justify-center font-mono font-bold text-2xl border shadow-sm shrink-0",
              Ravner.Governance.RiskScore.badge_classes(grade)
            ]}>
              {grade}
            </div>
            <div class="min-w-0 flex-1">
              <div class="flex items-baseline gap-1">
                <span class="text-3xl font-light font-mono text-neutral-900 dark:text-neutral-100">
                  {score || "—"}
                </span>
                <span class="text-xs font-light text-neutral-400">/ 100</span>
              </div>
              <div
                class="text-[11px] font-medium uppercase tracking-wider text-neutral-500 mt-0.5 truncate"
                title={
                  cond do
                    is_nil(score) or grade == "N/A" ->
                      "No scan telemetry recorded — cyber risk scoring pending initial scan"

                    score >= 90 ->
                      "Excellent Security Posture"

                    score >= 80 ->
                      "Good Posture (Minor Deductions)"

                    score >= 65 ->
                      "Moderate Risk Exposure"

                    score >= 50 ->
                      "High Risk Exposure"

                    true ->
                      "Critical Risk Exposure"
                  end
                }
              >
                <%= cond do %>
                  <% is_nil(score) or grade == "N/A" -> %>
                    Pending Scans
                  <% score >= 90 -> %>
                    Excellent Posture
                  <% score >= 80 -> %>
                    Good Posture
                  <% score >= 65 -> %>
                    Moderate Risk
                  <% score >= 50 -> %>
                    High Risk
                  <% true -> %>
                    Critical Risk
                <% end %>
              </div>
              <%!-- Visual score bar --%>
              <div class="w-full max-w-[130px] sm:max-w-[140px] bg-neutral-200 dark:bg-neutral-800 h-1.5 rounded-full mt-2 overflow-hidden">
                <%= if is_integer(score) do %>
                  <div
                    class={[
                      "h-full rounded-full transition-all duration-500",
                      score >= 90 && "bg-emerald-500",
                      score >= 80 && score < 90 && "bg-blue-500",
                      score >= 65 && score < 80 && "bg-amber-500",
                      score >= 50 && score < 65 && "bg-orange-500",
                      score < 50 && "bg-red-500"
                    ]}
                    style={"width: #{score}%"}
                  >
                  </div>
                <% else %>
                  <div class="h-full bg-neutral-300 dark:bg-neutral-700 w-0"></div>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Multi-factor Deductions Summary --%>
          <div class="lg:col-span-8 grid grid-cols-2 sm:grid-cols-3 gap-2.5 sm:gap-3 text-xs min-w-0">
            <div class="p-2.5 rounded bg-white dark:bg-neutral-800/80 border border-neutral-100 dark:border-neutral-700/60">
              <div class="text-[10px] uppercase tracking-wider text-neutral-400 mb-1">
                CVE Vulnerabilities
              </div>
              <div class={[
                "font-mono font-medium",
                is_nil(score) && "text-neutral-400",
                not is_nil(score) &&
                  (Map.get(deductions, "vulnerabilities", 0) ||
                     Map.get(deductions, :vulnerabilities, 0)) > 0 &&
                  "text-red-600 dark:text-red-400",
                not is_nil(score) &&
                  (Map.get(deductions, "vulnerabilities", 0) ||
                     Map.get(deductions, :vulnerabilities, 0)) == 0 &&
                  "text-emerald-600 dark:text-emerald-400"
              ]}>
                <%= if is_nil(score) do %>
                  <span class="text-neutral-400 font-light font-sans">Pending scan</span>
                <% else %>
                  <%= if (v = (Map.get(deductions, "vulnerabilities", 0) || Map.get(deductions, :vulnerabilities, 0))) > 0 do %>
                    -{v} pts
                  <% else %>
                    0 pts (Clean)
                  <% end %>
                <% end %>
              </div>
            </div>

            <div class="p-2.5 rounded bg-white dark:bg-neutral-800/80 border border-neutral-100 dark:border-neutral-700/60">
              <div class="text-[10px] uppercase tracking-wider text-neutral-400 mb-1">
                VCS Secret Leaks
              </div>
              <div class={[
                "font-mono font-medium",
                is_nil(score) && "text-neutral-400",
                not is_nil(score) &&
                  (Map.get(deductions, "secrets", 0) || Map.get(deductions, :secrets, 0)) >
                    0 && "text-red-600 dark:text-red-400",
                not is_nil(score) &&
                  (Map.get(deductions, "secrets", 0) || Map.get(deductions, :secrets, 0)) ==
                    0 && "text-emerald-600 dark:text-emerald-400"
              ]}>
                <%= if is_nil(score) do %>
                  <span class="text-neutral-400 font-light font-sans">Pending scan</span>
                <% else %>
                  <%= if (s = (Map.get(deductions, "secrets", 0) || Map.get(deductions, :secrets, 0))) > 0 do %>
                    -{s} pts
                  <% else %>
                    0 pts (Clean)
                  <% end %>
                <% end %>
              </div>
            </div>

            <div class="p-2.5 rounded bg-white dark:bg-neutral-800/80 border border-neutral-100 dark:border-neutral-700/60">
              <div class="text-[10px] uppercase tracking-wider text-neutral-400 mb-1">
                TLS / SSL Hygiene
              </div>
              <div class={[
                "font-mono font-medium",
                is_nil(score) && "text-neutral-400",
                not is_nil(score) &&
                  (Map.get(deductions, "ssl", 0) || Map.get(deductions, :ssl, 0)) > 0 &&
                  "text-amber-600 dark:text-amber-400",
                not is_nil(score) &&
                  (Map.get(deductions, "ssl", 0) || Map.get(deductions, :ssl, 0)) == 0 &&
                  "text-emerald-600 dark:text-emerald-400"
              ]}>
                <%= if is_nil(score) do %>
                  <span class="text-neutral-400 font-light font-sans">Pending scan</span>
                <% else %>
                  <%= if (ssl = (Map.get(deductions, "ssl", 0) || Map.get(deductions, :ssl, 0))) > 0 do %>
                    -{ssl} pts
                  <% else %>
                    0 pts (Valid)
                  <% end %>
                <% end %>
              </div>
            </div>

            <div class="p-2.5 rounded bg-white dark:bg-neutral-800/80 border border-neutral-100 dark:border-neutral-700/60">
              <div class="text-[10px] uppercase tracking-wider text-neutral-400 mb-1">
                HTTP Headers
              </div>
              <div class={[
                "font-mono font-medium",
                is_nil(score) && "text-neutral-400",
                not is_nil(score) &&
                  (Map.get(deductions, "headers", 0) || Map.get(deductions, :headers, 0)) >
                    0 && "text-amber-600 dark:text-amber-400",
                not is_nil(score) &&
                  (Map.get(deductions, "headers", 0) || Map.get(deductions, :headers, 0)) ==
                    0 && "text-emerald-600 dark:text-emerald-400"
              ]}>
                <%= if is_nil(score) do %>
                  <span class="text-neutral-400 font-light font-sans">Pending scan</span>
                <% else %>
                  <%= if (h = (Map.get(deductions, "headers", 0) || Map.get(deductions, :headers, 0))) > 0 do %>
                    -{h} pts
                  <% else %>
                    0 pts (Hardened)
                  <% end %>
                <% end %>
              </div>
            </div>

            <div class="p-2.5 rounded bg-white dark:bg-neutral-800/80 border border-neutral-100 dark:border-neutral-700/60">
              <div class="text-[10px] uppercase tracking-wider text-neutral-400 mb-1">
                Uptime Availability
              </div>
              <div class={[
                "font-mono font-medium",
                is_nil(score) && "text-neutral-400",
                not is_nil(score) &&
                  (Map.get(deductions, "uptime", 0) || Map.get(deductions, :uptime, 0)) >
                    0 && "text-red-600 dark:text-red-400",
                not is_nil(score) &&
                  (Map.get(deductions, "uptime", 0) || Map.get(deductions, :uptime, 0)) ==
                    0 && "text-emerald-600 dark:text-emerald-400"
              ]}>
                <%= if is_nil(score) do %>
                  <span class="text-neutral-400 font-light font-sans">Pending scan</span>
                <% else %>
                  <%= if (u = (Map.get(deductions, "uptime", 0) || Map.get(deductions, :uptime, 0))) > 0 do %>
                    -{u} pts
                  <% else %>
                    0 pts (Healthy)
                  <% end %>
                <% end %>
              </div>
            </div>

            <div class="p-2.5 rounded bg-white dark:bg-neutral-800/80 border border-neutral-100 dark:border-neutral-700/60">
              <div class="text-[10px] uppercase tracking-wider text-neutral-400 mb-1">
                Open Admin Ports
              </div>
              <div class={[
                "font-mono font-medium",
                is_nil(score) && "text-neutral-400",
                not is_nil(score) &&
                  (Map.get(deductions, "ports", 0) || Map.get(deductions, :ports, 0)) > 0 &&
                  "text-red-600 dark:text-red-400",
                not is_nil(score) &&
                  (Map.get(deductions, "ports", 0) || Map.get(deductions, :ports, 0)) == 0 &&
                  "text-emerald-600 dark:text-emerald-400"
              ]}>
                <%= if is_nil(score) do %>
                  <span class="text-neutral-400 font-light font-sans">Pending scan</span>
                <% else %>
                  <%= if (p = (Map.get(deductions, "ports", 0) || Map.get(deductions, :ports, 0))) > 0 do %>
                    -{p} pts
                  <% else %>
                    0 pts (Filtered)
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- Deduction Drivers / Findings Breakdown --%>
        <%= if drivers != [] do %>
          <div class="space-y-2">
            <div class="text-xs font-medium text-neutral-700 dark:text-neutral-300">
              Key Risk Drivers ({length(drivers)}):
            </div>
            <div class="space-y-1.5">
              <%= for driver <- drivers do %>
                <div class="flex items-start gap-2 text-xs p-2 rounded bg-neutral-50 dark:bg-neutral-800/50 border border-neutral-100 dark:border-neutral-800">
                  <.icon
                    name="hero-exclamation-triangle"
                    class="w-4 h-4 text-amber-500 shrink-0 mt-0.5"
                  />
                  <span class="text-neutral-700 dark:text-neutral-300 font-mono text-[11px]">
                    {driver}
                  </span>
                </div>
              <% end %>
            </div>
          </div>
        <% else %>
          <%= if is_integer(score) do %>
            <div class="flex items-center gap-2 text-xs p-3 rounded bg-emerald-50/50 dark:bg-emerald-950/20 text-emerald-800 dark:text-emerald-300 border border-emerald-200/50 dark:border-emerald-800/50">
              <.icon name="hero-check-badge" class="w-4 h-4 text-emerald-600 shrink-0" />
              <span>
                Zero posture deductions — enterprise cyber security baselines satisfied.
              </span>
            </div>
          <% end %>
        <% end %>
      <% end %>
    </div>

    <%= if @domain.domain_metadata do %>
      <div class="card-line">
        <h2 class="text-sm font-normal tracking-wide uppercase mb-6">HTTP</h2>
        <%= case @domain_class do %>
          <% {:external_redirect, target} -> %>
            <p class="text-sm font-light text-neutral-500 italic mb-4">
              N/A — redirects to <span class="font-normal text-neutral-700">{target}</span>
            </p>
          <% _ -> %>
            <div class="grid grid-cols-2 gap-6 text-sm">
              <div>
                <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
                  Status
                </span>
                <span :if={@domain.domain_metadata.http_status} class="font-light">
                  {@domain.domain_metadata.http_status}
                </span>
                <span
                  :if={!@domain.domain_metadata.http_status}
                  class="text-neutral-400 font-light"
                >
                  —
                </span>
              </div>
              <div>
                <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
                  Server
                </span>
                <span :if={@domain.domain_metadata.server_header} class="font-light">
                  {@domain.domain_metadata.server_header}
                </span>
                <span
                  :if={!@domain.domain_metadata.server_header}
                  class="text-neutral-400 font-light"
                >
                  —
                </span>
              </div>
            </div>
        <% end %>

        <div class="mt-4">
          <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-2">
            Final URL
          </span>
          <a
            :if={@domain.domain_metadata.final_url}
            href={@domain.domain_metadata.final_url}
            target="_blank"
            rel="noopener noreferrer"
            class="text-sm font-light break-all hover:underline inline-flex items-start gap-1.5 group"
          >
            <span>{@domain.domain_metadata.final_url}</span>
            <.icon
              name="hero-arrow-top-right-on-square"
              class="w-3.5 h-3.5 shrink-0 mt-0.5 text-neutral-400 group-hover:text-neutral-700 transition-colors"
            />
          </a>
          <span
            :if={!@domain.domain_metadata.final_url}
            class="text-sm font-light text-neutral-400"
          >
            —
          </span>
        </div>

        <%= if @domain.domain_metadata.redirect_chain && @domain.domain_metadata.redirect_chain != [] do %>
          <div class="mt-6 border-t border-neutral-100 pt-4">
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-3">
              Redirect Chain
            </span>
            <div class="space-y-2">
              <%= for {hop, idx} <- Enum.with_index(@domain.domain_metadata.redirect_chain) do %>
                <% is_last = idx == length(@domain.domain_metadata.redirect_chain) - 1 %>
                <div class="flex items-center gap-3 text-sm font-light">
                  <span class={[
                    "px-2 py-0.5 text-[10px] font-normal uppercase tracking-wide shrink-0",
                    if(hop["status"] >= 300 && hop["status"] < 400,
                      do: "text-yellow-700 bg-yellow-50 border border-yellow-200",
                      else:
                        "text-neutral-500 bg-neutral-50 border border-neutral-200 dark:text-neutral-400 dark:bg-neutral-800 dark:border-neutral-700"
                    )
                  ]}>
                    {hop["status"]}
                  </span>
                  <%= if is_last do %>
                    <a
                      href={hop["url"]}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="truncate hover:underline inline-flex items-center gap-1 group"
                    >
                      <span class="truncate">{hop["url"]}</span>
                      <.icon
                        name="hero-arrow-top-right-on-square"
                        class="w-3 h-3 shrink-0 text-neutral-400 group-hover:text-neutral-700 transition-colors"
                      />
                    </a>
                  <% else %>
                    <span class="truncate text-neutral-500">{hop["url"]}</span>
                    <.icon
                      name="hero-arrow-down-right"
                      class="w-3 h-3 shrink-0 text-neutral-300"
                    />
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if match?({:external_redirect, _}, @domain_class) do %>
        <% else %>
          <%= if @domain.domain_metadata.security_headers && @domain.domain_metadata.security_headers != %{} do %>
            <div class="mt-6 border-t border-neutral-100 pt-4">
              <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-3">
                Security Headers
              </span>
              <div class="space-y-1">
                <%= for {key, val} <- @domain.domain_metadata.security_headers do %>
                  <div class="flex justify-between text-xs font-light">
                    <span class="text-neutral-500">{key}</span>
                    <span :if={val} class="text-green-700 ml-2">✓</span>
                    <span :if={!val} class="text-neutral-400 ml-2">—</span>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>

        <div
          :if={@domain.domain_metadata.http_scanned_at}
          class="mt-4 pt-4 border-t border-neutral-100"
        >
          <span class="text-[10px] font-light text-neutral-400">
            Scanned {DateTime.to_iso8601(@domain.domain_metadata.http_scanned_at)}
          </span>
        </div>
      </div>

      <div :if={@domain.domain_metadata.ssl_valid_until} class="card-line">
        <h2 class="text-sm font-normal tracking-wide uppercase mb-6 flex items-center justify-between">
          SSL Certificate <% expiring_soon =
            @domain.domain_metadata.ssl_days_remaining != nil &&
              @domain.domain_metadata.ssl_days_remaining <= 14 %>
          <% expired =
            @domain.domain_metadata.ssl_days_remaining != nil &&
              @domain.domain_metadata.ssl_days_remaining < 0 %>
          <span class={[
            "text-[10px] font-normal px-2 py-0.5 border uppercase tracking-wider",
            expired && "text-red-700 bg-red-50 border-red-200",
            expiring_soon && !expired && "text-amber-700 bg-amber-50 border-amber-200",
            !expiring_soon && "text-green-700 bg-green-50 border-green-200"
          ]}>
            <%= if expired do %>
              Expired
            <% else %>
              {@domain.domain_metadata.ssl_days_remaining} days left
            <% end %>
          </span>
        </h2>

        <div class="space-y-4 text-sm font-light">
          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              Subject
            </span>
            <span class="break-all font-mono text-xs">
              {@domain.domain_metadata.ssl_subject}
            </span>
          </div>

          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              Issuer
            </span>
            <span class="break-all">
              {@domain.domain_metadata.ssl_issuer}
            </span>
          </div>

          <div class="grid grid-cols-2 gap-6">
            <div>
              <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
                Valid From
              </span>
              <span :if={@domain.domain_metadata.ssl_valid_from}>
                {Calendar.strftime(@domain.domain_metadata.ssl_valid_from, "%Y-%m-%d")}
              </span>
            </div>
            <div>
              <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
                Valid Until
              </span>
              <span :if={@domain.domain_metadata.ssl_valid_until}>
                {Calendar.strftime(@domain.domain_metadata.ssl_valid_until, "%Y-%m-%d")}
              </span>
            </div>
          </div>
        </div>
      </div>
    <% end %>

    <%= if @domain.domain_metadata && (@domain.domain_metadata.ip_v4 != [] || @domain.domain_metadata.ip_v6 != [] || @domain.dns_records != []) do %>
      <div class="card-line">
        <h2 class="text-sm font-normal tracking-wide uppercase mb-6">DNS</h2>

        <%= if @domain.domain_metadata.ip_v4 != [] do %>
          <div class="mb-4">
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-2">
              IPv4
            </span>
            <div class="flex flex-wrap gap-2">
              <%= for ip <- @domain.domain_metadata.ip_v4 do %>
                <span class="px-2 py-0.5 border border-neutral-200 text-xs font-mono font-light">
                  {ip}
                </span>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @domain.domain_metadata.ip_v6 != [] do %>
          <div class="mb-4">
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-2">
              IPv6
            </span>
            <div class="flex flex-wrap gap-2">
              <%= for ip <- @domain.domain_metadata.ip_v6 do %>
                <span class="px-2 py-0.5 border border-neutral-200 text-xs font-mono font-light">
                  {ip}
                </span>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @domain.dns_records != [] do %>
          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-2">
              Records
            </span>
            <div class="divide-y divide-neutral-100">
              <%= for rec <- @domain.dns_records do %>
                <div class="py-2 flex items-center gap-3 text-sm font-light">
                  <span class="px-1.5 py-0.5 border border-neutral-200 text-[10px] font-normal uppercase w-12 text-center">
                    {rec.type}
                  </span>
                  <span class="truncate">{rec.value}</span>
                  <span class="ml-auto text-[10px] text-neutral-400">TTL:{rec.ttl}</span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <div
          :if={@domain.domain_metadata.dns_scanned_at}
          class="mt-4 pt-4 border-t border-neutral-100"
        >
          <span class="text-[10px] font-light text-neutral-400">
            Scanned {DateTime.to_iso8601(@domain.domain_metadata.dns_scanned_at)}
          </span>
        </div>
      </div>
    <% end %>

    <%= if infrastructure_metadata?(@domain) && !match?({:external_redirect, _}, @domain_class) do %>
      <div class="card-line">
        <h2 class="text-sm font-normal tracking-wide uppercase mb-6">Infrastructure</h2>
        <div class="grid grid-cols-2 gap-6 text-sm">
          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              Hosting
            </span>
            <span :if={@domain.domain_metadata.hosting_platform} class="font-light">
              {@domain.domain_metadata.hosting_platform}
            </span>
            <span
              :if={!@domain.domain_metadata.hosting_platform}
              class="text-neutral-400 font-light"
            >
              —
            </span>
          </div>
          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              ASN
            </span>
            <%= if @domain.domain_metadata.asn_org || @domain.domain_metadata.asn_number do %>
              <span class="font-light">
                <%= if @domain.domain_metadata.asn_number do %>
                  <span class="font-mono text-xs text-neutral-500">
                    {@domain.domain_metadata.asn_number}
                  </span>
                  {" "}
                <% end %>
                {@domain.domain_metadata.asn_org}
              </span>
            <% else %>
              <span class="text-neutral-400 font-light">—</span>
            <% end %>
          </div>
        </div>

        <%= if @domain.domain_metadata.tech_stack && @domain.domain_metadata.tech_stack != [] do %>
          <div class="mt-4">
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-2">
              Tech Stack
            </span>
            <div class="flex flex-wrap gap-2">
              <%= for tech <- @domain.domain_metadata.tech_stack do %>
                <span class="px-2 py-0.5 border border-neutral-200 text-xs font-light">
                  {tech}
                </span>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @domain.tech_evidence != [] do %>
          <div class="mt-6 pt-5 border-t border-neutral-100">
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-3">
              Deep Tech Evidence
            </span>
            <div class="space-y-2">
              <%= for item <- Enum.take(@domain.tech_evidence, 12) do %>
                <div class="flex items-center justify-between gap-3 text-xs">
                  <div class="min-w-0 flex items-center gap-1.5">
                    <span class="font-light text-neutral-900">{item.name}</span>
                    <span
                      :if={item.version}
                      class="font-mono text-[10px] text-neutral-500 bg-neutral-100 px-1 py-0.5 rounded"
                    >
                      v{item.version}
                    </span>
                  </div>
                  <div class="flex items-center gap-1.5 shrink-0">
                    <%= if item.source && String.contains?(item.source, "implied") do %>
                      <span class="text-[9px] uppercase tracking-wider text-amber-700 bg-amber-50 border border-amber-200/60 px-1.5 py-0.5 rounded font-mono">
                        implied
                      </span>
                    <% else %>
                      <span class="text-[9px] uppercase tracking-wider text-neutral-500 bg-neutral-100 px-1.5 py-0.5 rounded font-mono">
                        {if item.source && String.starts_with?(item.source, "wappalyzer:"),
                          do: "direct",
                          else: item.source || "direct"}
                      </span>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @domain.discovered_urls != [] do %>
          <div class="mt-6 pt-5 border-t border-neutral-100">
            <div class="flex items-center justify-between gap-3 mb-3">
              <span class="text-xs font-light tracking-wide uppercase text-neutral-500">
                Crawled URLs
              </span>
              <span class="text-[10px] text-neutral-400">
                {length(@domain.discovered_urls)}
              </span>
            </div>
            <div class="space-y-1.5">
              <%= for item <- Enum.take(@domain.discovered_urls, 10) do %>
                <a
                  href={item.url}
                  target="_blank"
                  rel="noreferrer"
                  class="group flex items-center gap-2 text-xs font-light text-neutral-600 hover:text-neutral-950"
                >
                  <span class="truncate">{item.url}</span>
                  <.icon
                    name="hero-arrow-top-right-on-square"
                    class="w-3 h-3 shrink-0 opacity-40 group-hover:opacity-100"
                  />
                </a>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @domain.domain_metadata.js_assets && @domain.domain_metadata.js_assets != [] do %>
          <div class="mt-6 pt-5 border-t border-neutral-100">
            <div class="flex items-center justify-between gap-3 mb-3">
              <span class="text-xs font-light tracking-wide uppercase text-neutral-500">
                JavaScript Assets
              </span>
              <span class="text-[10px] text-neutral-400">
                {length(@domain.domain_metadata.js_assets)}
              </span>
            </div>
            <div class="space-y-1.5">
              <%= for url <- Enum.take(@domain.domain_metadata.js_assets, 8) do %>
                <a
                  href={url}
                  target="_blank"
                  rel="noreferrer"
                  class="group flex items-center gap-2 text-xs font-light text-neutral-600 hover:text-neutral-950"
                >
                  <span class="truncate">{url}</span>
                  <.icon
                    name="hero-arrow-top-right-on-square"
                    class="w-3 h-3 shrink-0 opacity-40 group-hover:opacity-100"
                  />
                </a>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @domain.domain_metadata.deep_scan_errors && @domain.domain_metadata.deep_scan_errors != [] do %>
          <div class="mt-6 pt-5 border-t border-neutral-100">
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-2">
              Tool Warnings
            </span>
            <div class="space-y-1">
              <%= for warning <- @domain.domain_metadata.deep_scan_errors do %>
                <p class="text-xs font-light text-amber-700">{warning}</p>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @domain.domain_metadata.open_ports && @domain.domain_metadata.open_ports != [] do %>
          <div class="mt-4">
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-2">
              Open Ports
            </span>
            <div class="flex flex-wrap gap-1">
              <%= for port <- @domain.domain_metadata.open_ports do %>
                <span class="text-[11px] font-mono px-1.5 py-0.5 border border-neutral-200 text-neutral-600 rounded-sm">
                  {port}
                </span>
              <% end %>
            </div>
          </div>
        <% end %>

        <div
          :if={@domain.domain_metadata.deep_tech_scanned_at}
          class="mt-4 pt-4 border-t border-neutral-100"
        >
          <span class="text-[10px] font-light text-neutral-400">
            Deep scanned {DateTime.to_iso8601(@domain.domain_metadata.deep_tech_scanned_at)}
          </span>
        </div>
      </div>
    <% end %>

    <.live_component
      module={RavnerWeb.DomainLive.VcsPanel}
      id="domain-vcs-panel"
      domain={@domain}
      domain_repos={@domain_repos}
      primary_repo={@primary_repo}
      project_repos={@project_repos}
      can_manage?={@can_manage?}
      can_scan?={@can_scan?}
      current_scope={@current_scope}
    />

    <%= if @domain.domain_metadata && (@domain.domain_metadata.registrar || @domain.domain_metadata.registration_date || @domain.domain_metadata.expiration_date || @domain.domain_metadata.registrant_org) do %>
      <% now = DateTime.utc_now() %>
      <% days_remaining =
        @domain.domain_metadata.expiration_date &&
          DateTime.diff(@domain.domain_metadata.expiration_date, now, :day) %>
      <% expired = days_remaining != nil && days_remaining < 0 %>
      <% expiring_soon = days_remaining != nil && days_remaining <= 14 && !expired %>
      <div class="card-line">
        <h2 class="text-sm font-normal tracking-wide uppercase mb-6 flex items-center justify-between">
          Registration
          <span
            :if={@domain.domain_metadata.expiration_date}
            class={[
              "text-[10px] font-normal px-2 py-0.5 border uppercase tracking-wider",
              expired && "text-red-700 bg-red-50 border-red-200",
              expiring_soon && "text-amber-700 bg-amber-50 border-amber-200",
              !expired && !expiring_soon && "text-green-700 bg-green-50 border-green-200"
            ]}
          >
            <%= if expired do %>
              Expired
            <% else %>
              {days_remaining} days left
            <% end %>
          </span>
        </h2>
        <div class="grid grid-cols-2 gap-6 text-sm">
          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              Registrar
            </span>
            <span :if={@domain.domain_metadata.registrar} class="font-light">
              {@domain.domain_metadata.registrar}
            </span>
            <span
              :if={!@domain.domain_metadata.registrar}
              class="text-neutral-400 font-light"
            >
              —
            </span>
          </div>
          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              Registrant
            </span>
            <span :if={@domain.domain_metadata.registrant_org} class="font-light">
              {@domain.domain_metadata.registrant_org}
            </span>
            <span
              :if={!@domain.domain_metadata.registrant_org}
              class="text-neutral-400 font-light"
            >
              —
            </span>
          </div>
          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              Registered
            </span>
            <span
              :if={@domain.domain_metadata.registration_date}
              class="font-light font-mono text-xs"
            >
              {DateTime.to_iso8601(@domain.domain_metadata.registration_date)}
            </span>
            <span
              :if={!@domain.domain_metadata.registration_date}
              class="text-neutral-400 font-light"
            >
              —
            </span>
          </div>
          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              Expires
            </span>
            <span
              :if={@domain.domain_metadata.expiration_date}
              class="font-light font-mono text-xs"
            >
              {DateTime.to_iso8601(@domain.domain_metadata.expiration_date)}
            </span>
            <span
              :if={!@domain.domain_metadata.expiration_date}
              class="text-neutral-400 font-light"
            >
              —
            </span>
          </div>
        </div>

        <%= if @domain.domain_metadata.contacts && map_size(@domain.domain_metadata.contacts) > 0 do %>
          <div class="mt-6 pt-6 border-t border-neutral-100">
            <h3 class="text-xs font-normal tracking-wide uppercase text-neutral-600 mb-4">
              Contacts
            </h3>
            <div class="space-y-3">
              <%= for {role, contact} <- @domain.domain_metadata.contacts do %>
                <div class="text-sm">
                  <p class="text-xs uppercase tracking-wide text-neutral-400 mb-1">
                    {String.capitalize(role)}
                  </p>
                  <div class="space-y-0.5 text-xs font-light">
                    <%= if contact["name"] do %>
                      <p class="text-neutral-700">{contact["name"]}</p>
                    <% end %>
                    <%= if contact["email"] do %>
                      <p class="text-neutral-500">{contact["email"]}</p>
                    <% end %>
                    <%= if contact["phone"] do %>
                      <p class="text-neutral-500">{contact["phone"]}</p>
                    <% end %>
                    <%= if !contact["name"] && !contact["email"] && !contact["phone"] do %>
                      <p class="text-neutral-400">—</p>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <div
          :if={@domain.domain_metadata.rdap_scanned_at}
          class="mt-4 pt-4 border-t border-neutral-100"
        >
          <span class="text-[10px] font-light text-neutral-400">
            Scanned {DateTime.to_iso8601(@domain.domain_metadata.rdap_scanned_at)}
          </span>
        </div>
      </div>
    <% end %>
    """
  end

  defp infrastructure_metadata?(domain) do
    metadata = domain.domain_metadata

    (metadata &&
       (metadata.hosting_platform || metadata.asn_org ||
          populated?(metadata.tech_stack) ||
          populated?(metadata.js_assets) ||
          populated?(metadata.open_ports))) ||
      populated?(domain.tech_evidence) ||
      populated?(domain.discovered_urls)
  end

  defp populated?(value), do: is_list(value) && value != []
end
