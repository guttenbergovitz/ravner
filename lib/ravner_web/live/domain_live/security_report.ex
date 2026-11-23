defmodule RavnerWeb.DomainLive.SecurityReport do
  @moduledoc """
  Comprehensive security findings and threat posture report for a domain.

  Aggregates and categorizes findings from:
  - Curated high-impact exposure probes (.env, .git, debug panels)
  - Zero-lag OSV.dev CVE vulnerability intelligence
  - In-process TLS protocol and HTTP security headers audit
  - Sensitive TCP ports and exposed database services
  - Hudson Rock dark web infostealer & credential intelligence
  """
  use RavnerWeb, :live_view

  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Scans.SecurityRunner
  alias Ravner.SecurityScans

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    domain = Domains.get_domain_with_preloads!(id)

    if Ravner.Accounts.ScopeResolver.can_view_domain?(socket.assigns[:current_scope], domain) do
      # Non-scannable domains (redirects, placeholders, archived) → redirect to domain show
      if not Domain.scannable?(domain) do
        {:ok,
         socket
         |> put_flash(
           :info,
           "Security scanning not applicable for #{domain.lifecycle_state} domains."
         )
         |> push_navigate(to: ~p"/domains/#{domain.id}")}
      else
        socket =
          socket
          |> assign(:domain, domain)
          |> assign(:page_title, "Security Report — #{domain.name}")
          |> assign(:active_tab, :all)
          |> assign(:selected_severity, nil)
          |> assign(:search_query, "")
          |> assign(:selected_finding, nil)
          |> load_report_data(domain.id)

        {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have permission to view this domain.")
       |> push_navigate(to: ~p"/domains")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab =
      case params["tab"] do
        "cves" -> :cves
        "exposures" -> :exposures
        "tls_headers" -> :tls_headers
        "ports" -> :ports
        "breach" -> :breach
        "history" -> :history
        _ -> :all
      end

    severity =
      case params["severity"] do
        s when s in ["critical", "high", "medium", "low", "info"] -> s
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> assign(:selected_severity, severity)}
  end

  # ─── Event Handlers ────────────────────────────────────────────────────────

  @tab_map %{
    "all" => :all,
    "cves" => :cves,
    "exposures" => :exposures,
    "tls_headers" => :tls_headers,
    "ports" => :ports,
    "breach" => :breach,
    "history" => :history
  }

  @impl true
  def handle_event("set_tab", %{"tab" => tab_str}, socket) do
    tab = Map.get(@tab_map, tab_str, :all)
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("filter_severity", %{"severity" => severity}, socket) do
    new_severity = if severity == "all" or severity == "", do: nil, else: severity
    {:noreply, assign(socket, :selected_severity, new_severity)}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, assign(socket, :search_query, query)}
  end

  @impl true
  def handle_event("select_finding", %{"id" => id_str}, socket) do
    finding_id = String.to_integer(id_str)
    finding = Enum.find(socket.assigns.all_findings, &(&1.id == finding_id))
    {:noreply, assign(socket, :selected_finding, finding)}
  end

  @impl true
  def handle_event("close_finding_detail", _params, socket) do
    {:noreply, assign(socket, :selected_finding, nil)}
  end

  @impl true
  def handle_event("run_security_scan", _params, socket) do
    if Ravner.Accounts.ScopeResolver.can_scan_domain?(
         socket.assigns.current_scope,
         socket.assigns.domain
       ) do
      domain = socket.assigns.domain
      liveview_pid = self()
      user_id = socket.assigns.current_scope.user.id

      if socket.assigns.running_scan do
        {:noreply, put_flash(socket, :error, "A scan is already in progress.")}
      else
        case SecurityRunner.run_security_scan(domain.id, liveview_pid, user_id, :light) do
          {:ok, scan} ->
            {:noreply,
             socket
             |> assign(:running_scan, scan)
             |> put_flash(:info, "Lightweight security scan initiated.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
    end
  end

  @impl true
  def handle_event("run_breach_scan", _params, socket) do
    if Ravner.Accounts.ScopeResolver.can_scan_domain?(
         socket.assigns.current_scope,
         socket.assigns.domain
       ) do
      domain = socket.assigns.domain
      liveview_pid = self()
      user_id = socket.assigns.current_scope.user.id

      if socket.assigns.running_scan do
        {:noreply, put_flash(socket, :error, "A scan is already in progress.")}
      else
        case SecurityRunner.run_breach_scan(domain.id, liveview_pid, user_id) do
          {:ok, scan} ->
            {:noreply,
             socket
             |> assign(:running_scan, scan)
             |> put_flash(:info, "Dark web breach scan initiated.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
    end
  end

  @impl true
  def handle_event("run_repo_scan", _params, socket) do
    if Ravner.Accounts.ScopeResolver.can_scan_domain?(
         socket.assigns.current_scope,
         socket.assigns.domain
       ) do
      domain = socket.assigns.domain

      {:ok, results} = Ravner.Scans.RepoScanner.scan_domain_repositories(domain.id)

      total_vulns =
        Enum.reduce(results, 0, fn
          %{vulnerabilities: v}, acc -> acc + length(v)
          _, acc -> acc
        end)

      msg =
        if total_vulns == 0 do
          "Repository scan completed — 0 dependency vulnerabilities found (Clean)."
        else
          "Repository scan completed — #{total_vulns} dependency vulnerabilities found."
        end

      {:noreply,
       socket
       |> load_report_data(domain.id)
       |> put_flash(:info, msg)}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to perform this action.")}
    end
  end

  # ─── LiveView Background Progress ──────────────────────────────────────────

  @impl true
  def handle_info({:scan_progress, scan_id, progress}, socket) do
    running =
      if socket.assigns.running_scan && socket.assigns.running_scan.id == scan_id do
        %{socket.assigns.running_scan | progress: progress}
      else
        SecurityScans.running_scan(socket.assigns.domain.id)
      end

    {:noreply, assign(socket, :running_scan, running)}
  end

  @impl true
  def handle_info({:scan_done, :security_scan, {:ok, scan}}, socket) do
    {:noreply,
     socket
     |> load_report_data(socket.assigns.domain.id)
     |> assign(:running_scan, nil)
     |> put_flash(:info, "Scan completed — #{scan.summary}")}
  end

  @impl true
  def handle_info({:scan_done, :security_scan, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> load_report_data(socket.assigns.domain.id)
     |> assign(:running_scan, nil)
     |> put_flash(:error, "Scan failed: #{reason}")}
  end

  @impl true
  def handle_info(:refresh_security_scans, socket) do
    {:noreply, load_report_data(socket, socket.assigns.domain.id)}
  end

  @impl true
  def handle_info({:repo_scan_done, {:ok, results}}, socket) do
    total_vulns =
      Enum.reduce(results, 0, fn
        %{vulnerabilities: v}, acc -> acc + length(v)
        _, acc -> acc
      end)

    msg =
      if total_vulns == 0 do
        "Repository scan completed — 0 dependency vulnerabilities found (Clean)."
      else
        "Repository scan completed — #{total_vulns} dependency vulnerabilities found."
      end

    {:noreply,
     socket
     |> load_report_data(socket.assigns.domain.id)
     |> put_flash(:info, msg)}
  end

  @impl true
  def handle_info({:repo_scan_done, {:error, reason}}, socket) do
    {:noreply, put_flash(socket, :error, "Repository scan failed: #{inspect(reason)}")}
  end

  # ─── Template Rendering ────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-6xl mx-auto px-6 py-8">
        <%!-- Breadcrumb --%>
        <nav class="flex items-center gap-1 text-xs font-light text-neutral-500 mb-4">
          <.link navigate={~p"/domains"} class="hover:text-neutral-900 transition-colors">
            Domains
          </.link>
          <.icon name="hero-chevron-right" class="w-3 h-3" />
          <.link
            navigate={~p"/domains/#{@domain.id}"}
            class="hover:text-neutral-900 transition-colors"
          >
            {@domain.name}
          </.link>
          <.icon name="hero-chevron-right" class="w-3 h-3" />
          <span class="text-neutral-900 font-medium">Security Report</span>
        </nav>

        <%!-- Header --%>
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 mb-8">
          <div>
            <div class="flex items-center gap-3">
              <h1 class="text-2xl font-light tracking-tight">Security & Threat Report</h1>
              <span class="text-xs font-mono text-neutral-400 bg-neutral-100 px-2 py-0.5 rounded">
                {@domain.name}
              </span>
            </div>
            <p class="text-xs font-light text-neutral-500 mt-1">
              Automated in-process audit: CVE vulnerabilities, sensitive file exposures, TLS & security headers, port exposure, and dark web infostealers.
            </p>
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <%= if Ravner.Accounts.ScopeResolver.can_scan_domain?(@current_scope, @domain) do %>
              <button
                id="run-repo-scan-btn"
                phx-click="run_repo_scan"
                disabled={!is_nil(@running_scan)}
                class={[
                  "btn-line text-xs inline-flex items-center gap-1.5 text-emerald-700 border-emerald-300 hover:bg-emerald-50 dark:text-emerald-300 dark:border-emerald-700 dark:hover:bg-emerald-950",
                  !is_nil(@running_scan) && "opacity-50 cursor-not-allowed"
                ]}
                title="Scan connected code repositories for dependency CVEs via OSV.dev"
              >
                <.icon
                  name="hero-code-bracket"
                  class="w-3.5 h-3.5 text-emerald-600 dark:text-emerald-400"
                /> Scan Repositories
              </button>

              <button
                id="run-security-scan-btn"
                phx-click="run_security_scan"
                disabled={!is_nil(@running_scan)}
                class={[
                  "btn-line text-xs inline-flex items-center gap-1.5",
                  !is_nil(@running_scan) && "opacity-50 cursor-not-allowed"
                ]}
              >
                <.icon name="hero-bolt" class="w-3.5 h-3.5 text-blue-600" /> Run Security Scan
              </button>

              <button
                id="run-breach-scan-btn"
                phx-click="run_breach_scan"
                disabled={!is_nil(@running_scan)}
                class={[
                  "btn-line text-xs inline-flex items-center gap-1.5 text-neutral-600 hover:text-red-600",
                  !is_nil(@running_scan) && "opacity-50 cursor-not-allowed"
                ]}
              >
                <.icon name="hero-finger-print" class="w-3.5 h-3.5 text-red-500" />
                Check Dark Web Leaks
              </button>
            <% end %>
          </div>
        </div>

        <%!-- Active scan progress banner --%>
        <%= if @running_scan do %>
          <div class="mb-6 border border-yellow-200 bg-yellow-50/70 rounded-lg p-4">
            <div class="flex items-center justify-between mb-2">
              <span class="text-xs font-medium text-yellow-900 flex items-center gap-2">
                <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin text-yellow-600" />
                Scan in Progress ({scan_tool_title(@running_scan.tool)})
              </span>
              <span class="text-xs font-mono font-medium text-yellow-800">
                {@running_scan.progress}%
              </span>
            </div>
            <div class="w-full h-1.5 bg-yellow-200 rounded-full overflow-hidden">
              <div
                class="h-full bg-yellow-500 transition-all duration-500"
                style={"width: #{@running_scan.progress}%"}
              >
              </div>
            </div>
          </div>
        <% end %>

        <%!-- High-Level Posture Metrics Grid --%>
        <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3 mb-8">
          <%!-- Total Findings --%>
          <div class="card-line p-4">
            <div class="text-[10px] uppercase tracking-wider text-neutral-500 mb-1">
              Total Findings
            </div>
            <div class="text-2xl font-light text-neutral-900">
              {length(@all_findings)}
            </div>
            <div class="flex items-center gap-2 mt-2 text-[11px]">
              <span class="text-red-600 font-medium font-mono">{@severity_counts.critical} crit</span>
              <span class="text-neutral-300">·</span>
              <span class="text-orange-600 font-medium font-mono">{@severity_counts.high} high</span>
              <span class="text-neutral-300">·</span>
              <span class="text-yellow-600 font-medium font-mono">{@severity_counts.medium} med</span>
            </div>
          </div>

          <%!-- CVE Vulnerabilities --%>
          <div class="card-line p-4">
            <div class="text-[10px] uppercase tracking-wider text-neutral-500 mb-1">Known CVEs</div>
            <div class="text-2xl font-light text-neutral-900">
              {length(@cve_findings)}
            </div>
            <div class="text-[11px] text-neutral-400 font-light mt-2 truncate">
              Google OSV.dev Intelligence
            </div>
          </div>

          <%!-- Exposures & Probes --%>
          <div class="card-line p-4">
            <div class="text-[10px] uppercase tracking-wider text-neutral-500 mb-1">
              Exposed Files & Panels
            </div>
            <div class="text-2xl font-light text-neutral-900">
              {length(@exposure_findings)}
            </div>
            <div class="text-[11px] text-neutral-400 font-light mt-2 truncate">
              .env, .git, actuators, debuggers
            </div>
          </div>

          <%!-- Open Ports --%>
          <div class="card-line p-4">
            <div class="text-[10px] uppercase tracking-wider text-neutral-500 mb-1">
              Exposed Ports
            </div>
            <div class="text-2xl font-light text-neutral-900">
              {length(@port_findings)}
            </div>
            <div class="text-[11px] text-neutral-400 font-light mt-2 truncate">
              Databases & admin services
            </div>
          </div>

          <%!-- Dark Web Leaks --%>
          <div class="card-line p-4">
            <div class="text-[10px] uppercase tracking-wider text-neutral-500 mb-1">
              Dark Web Infostealers
            </div>
            <div class="flex items-center gap-2 mt-0.5">
              <%= if @latest_breach_scan do %>
                <% heat =
                  get_in(
                    (@latest_breach_scan.raw_output &&
                       Jason.decode(@latest_breach_scan.raw_output) |> elem(1)) || %{},
                    ["heat"]
                  ) || "clean" %>
                <span class={[
                  "inline-flex items-center gap-1 text-xs font-medium px-2 py-0.5 rounded border",
                  heat == "hot" && "bg-red-50 text-red-700 border-red-200",
                  heat == "recent" && "bg-orange-50 text-orange-700 border-orange-200",
                  heat == "historical" && "bg-neutral-100 text-neutral-700 border-neutral-200",
                  heat == "clean" && "bg-green-50 text-green-700 border-green-200"
                ]}>
                  <%= if heat == "hot" do %>
                    <.icon name="hero-fire" class="w-3.5 h-3.5 text-red-600" />
                  <% end %>
                  {String.upcase(heat)}
                </span>
              <% else %>
                <span class="text-sm font-light text-neutral-400">Not checked</span>
              <% end %>
            </div>
            <div class="text-[11px] text-neutral-400 font-light mt-2 truncate">
              Hudson Rock OSINT
            </div>
          </div>
        </div>

        <%!-- Tab Navigation --%>
        <div class="border-b border-neutral-200 mb-6">
          <div class="flex items-center gap-1 overflow-x-auto text-xs">
            <.tab_button
              variant={:compact}
              active={@active_tab == :all}
              count={length(@all_findings)}
              phx-click="set_tab"
              phx-value-tab="all"
            >
              All Findings
            </.tab_button>
            <.tab_button
              variant={:compact}
              active={@active_tab == :cves}
              count={length(@cve_findings)}
              phx-click="set_tab"
              phx-value-tab="cves"
            >
              CVEs & Vulnerabilities
            </.tab_button>
            <.tab_button
              variant={:compact}
              active={@active_tab == :exposures}
              count={length(@exposure_findings)}
              phx-click="set_tab"
              phx-value-tab="exposures"
            >
              Exposed Files & Panels
            </.tab_button>
            <.tab_button
              variant={:compact}
              active={@active_tab == :tls_headers}
              count={length(@tls_header_findings)}
              phx-click="set_tab"
              phx-value-tab="tls_headers"
            >
              TLS & Security Headers
            </.tab_button>
            <.tab_button
              variant={:compact}
              active={@active_tab == :ports}
              count={length(@port_findings)}
              phx-click="set_tab"
              phx-value-tab="ports"
            >
              Exposed Ports
            </.tab_button>
            <.tab_button
              variant={:compact}
              active={@active_tab == :breach}
              count={length(@breach_findings)}
              phx-click="set_tab"
              phx-value-tab="breach"
            >
              Dark Web Intelligence
            </.tab_button>
            <.tab_button
              variant={:compact}
              active={@active_tab == :history}
              count={length(@past_scans)}
              phx-click="set_tab"
              phx-value-tab="history"
            >
              Scan History
            </.tab_button>
          </div>
        </div>

        <%!-- Tab Content --%>
        <%= cond do %>
          <% @active_tab == :history -> %>
            <.scan_history_tab scans={@past_scans} />
          <% @active_tab == :breach -> %>
            <.breach_intelligence_tab
              latest_breach_scan={@latest_breach_scan}
              findings={@breach_findings}
              domain={@domain}
            />
          <% true -> %>
            <%!-- Finding Filters Bar --%>
            <div class="flex flex-col sm:flex-row items-center justify-between gap-3 mb-6">
              <%!-- Search Input --%>
              <div class="relative w-full sm:w-72">
                <.icon
                  name="hero-magnifying-glass"
                  class="w-4 h-4 text-neutral-400 absolute left-3 top-1/2 -translate-y-1/2 pointer-events-none"
                />
                <input
                  type="text"
                  placeholder="Filter findings by title, package, path…"
                  value={@search_query}
                  phx-keyup="search"
                  phx-debounce="150"
                  class="w-full text-xs font-light pl-9 pr-3 py-1.5 border border-neutral-200 rounded-md focus:border-neutral-900 focus:outline-none"
                />
              </div>

              <%!-- Severity Pills --%>
              <div class="flex items-center gap-1.5 self-start sm:self-auto overflow-x-auto">
                <.severity_pill
                  label="All"
                  count={nil}
                  active={is_nil(@selected_severity)}
                  value="all"
                />
                <.severity_pill
                  label="Critical"
                  count={count_by_severity(current_tab_findings(assigns), "critical")}
                  active={@selected_severity == "critical"}
                  value="critical"
                  variant="critical"
                />
                <.severity_pill
                  label="High"
                  count={count_by_severity(current_tab_findings(assigns), "high")}
                  active={@selected_severity == "high"}
                  value="high"
                  variant="high"
                />
                <.severity_pill
                  label="Medium"
                  count={count_by_severity(current_tab_findings(assigns), "medium")}
                  active={@selected_severity == "medium"}
                  value="medium"
                  variant="medium"
                />
                <.severity_pill
                  label="Low"
                  count={count_by_severity(current_tab_findings(assigns), "low")}
                  active={@selected_severity == "low"}
                  value="low"
                  variant="low"
                />
                <.severity_pill
                  label="Info"
                  count={count_by_severity(current_tab_findings(assigns), "info")}
                  active={@selected_severity == "info"}
                  value="info"
                  variant="info"
                />
              </div>
            </div>

            <% displayed_findings = filtered_findings(assigns) %>

            <%= if displayed_findings == [] do %>
              <div class="card-line py-16 text-center">
                <.icon name="hero-check-badge" class="w-10 h-10 text-green-500 mx-auto mb-2" />
                <h3 class="text-sm font-medium text-neutral-900">No findings matched</h3>
                <p class="text-xs font-light text-neutral-500 mt-1 max-w-sm mx-auto">
                  <%= if @search_query != "" || @selected_severity do %>
                    No security findings match your active filters. Try clearing the filter or search query.
                  <% else %>
                    No security issues detected for this category in the latest completed audit.
                  <% end %>
                </p>
              </div>
            <% else %>
              <div class="space-y-3">
                <%= for finding <- displayed_findings do %>
                  <.finding_card finding={finding} />
                <% end %>
              </div>
            <% end %>
        <% end %>

        <%!-- Finding Detail Modal --%>
        <%= if @selected_finding do %>
          <.finding_modal finding={@selected_finding} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ─── Functional Components ─────────────────────────────────────────────────

  attr :label, :string, required: true
  attr :count, :any, default: nil
  attr :active, :boolean, default: false
  attr :value, :string, required: true
  attr :variant, :string, default: "default"

  defp severity_pill(assigns) do
    ~H"""
    <button
      phx-click="filter_severity"
      phx-value-severity={@value}
      class={[
        "text-[11px] font-medium px-2.5 py-1 rounded-full border transition-colors inline-flex items-center gap-1",
        @active && @variant == "critical" && "bg-red-600 text-white border-red-600",
        @active && @variant == "high" && "bg-orange-600 text-white border-orange-600",
        @active && @variant == "medium" && "bg-yellow-500 text-white border-yellow-500",
        @active && @variant == "low" && "bg-blue-600 text-white border-blue-600",
        @active && @variant == "info" && "bg-neutral-800 text-white border-neutral-800",
        @active && @variant == "default" && "bg-neutral-900 text-white border-neutral-900",
        !@active && "bg-white text-neutral-600 border-neutral-200 hover:border-neutral-400"
      ]}
    >
      {@label}
      <%= if @count do %>
        <span class="opacity-75 font-mono text-[10px]">({@count})</span>
      <% end %>
    </button>
    """
  end

  attr :finding, :map, required: true

  defp finding_card(assigns) do
    ~H"""
    <div
      id={"finding-#{@finding.id}"}
      class="card-line p-4 hover:border-neutral-300 transition-colors cursor-pointer"
      phx-click="select_finding"
      phx-value-id={@finding.id}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2 mb-1 flex-wrap">
            <span class={[
              "text-[10px] uppercase tracking-wider px-2 py-0.5 rounded font-semibold",
              @finding.severity == "critical" && "bg-red-50 text-red-700 border border-red-200",
              @finding.severity == "high" && "bg-orange-50 text-orange-700 border border-orange-200",
              @finding.severity == "medium" && "bg-yellow-50 text-yellow-700 border border-yellow-200",
              @finding.severity == "low" && "bg-blue-50 text-blue-700 border border-blue-200",
              @finding.severity == "info" &&
                "bg-neutral-100 text-neutral-700 border border-neutral-200"
            ]}>
              {@finding.severity}
            </span>

            <%= if category_label(@finding) do %>
              <span class="text-[10px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-neutral-100 text-neutral-600 font-mono">
                {category_label(@finding)}
              </span>
            <% end %>

            <span class="text-xs font-medium text-neutral-900 hover:text-blue-600 transition-colors">
              {@finding.title}
            </span>
          </div>

          <p class="text-xs text-neutral-500 font-mono font-light truncate mt-0.5">
            {@finding.target}
          </p>

          <%= if @finding.detail && is_map(@finding.detail) do %>
            <% detail = @finding.detail %>
            <%= if detail["description"] || detail["summary"] do %>
              <p class="text-xs text-neutral-600 font-light mt-2 line-clamp-2 leading-relaxed">
                {detail["description"] || detail["summary"]}
              </p>
            <% end %>

            <%= if detail["evidence"] do %>
              <div class="mt-2 bg-neutral-50 border border-neutral-100 rounded px-2.5 py-1.5 font-mono text-[11px] text-neutral-700 truncate">
                <span class="text-neutral-400 font-sans mr-1">Evidence:</span>
                {detail["evidence"]}
              </div>
            <% end %>
          <% end %>
        </div>

        <div class="shrink-0 flex items-center text-neutral-400 hover:text-neutral-700 pt-1">
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </div>
      </div>
    </div>
    """
  end

  attr :finding, :map, required: true

  defp finding_modal(assigns) do
    assigns = assign(assigns, :detail, assigns.finding.detail || %{})

    ~H"""
    <div class="fixed inset-0 bg-black/60 z-50 flex items-center justify-center p-4">
      <div class="bg-white rounded-lg max-w-3xl w-full max-h-[85vh] overflow-hidden flex flex-col shadow-xl">
        <div class="flex items-center justify-between p-6 border-b border-neutral-200">
          <div class="flex items-center gap-2">
            <span class={[
              "text-[10px] uppercase tracking-wider px-2 py-0.5 rounded font-semibold",
              @finding.severity == "critical" && "bg-red-50 text-red-700 border border-red-200",
              @finding.severity == "high" && "bg-orange-50 text-orange-700 border border-orange-200",
              @finding.severity == "medium" && "bg-yellow-50 text-yellow-700 border border-yellow-200",
              @finding.severity == "low" && "bg-blue-50 text-blue-700 border border-blue-200",
              @finding.severity == "info" &&
                "bg-neutral-100 text-neutral-700 border border-neutral-200"
            ]}>
              {@finding.severity}
            </span>
            <h2 class="text-base font-medium text-neutral-900">
              {@finding.title}
            </h2>
          </div>
          <button
            phx-click="close_finding_detail"
            class="text-neutral-400 hover:text-neutral-900 transition-colors p-1"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <div class="overflow-y-auto flex-1 p-6 space-y-5 text-xs">
          <%!-- Target URL / Service --%>
          <div>
            <h4 class="font-medium text-neutral-500 uppercase tracking-wider text-[10px] mb-1">
              Target
            </h4>
            <div class="bg-neutral-50 border border-neutral-200 rounded p-2.5 font-mono text-[11px] text-neutral-800 break-all select-all">
              {@finding.target}
            </div>
          </div>

          <%!-- Description --%>
          <%= if @detail["description"] || @detail["summary"] do %>
            <div>
              <h4 class="font-medium text-neutral-500 uppercase tracking-wider text-[10px] mb-1">
                Description
              </h4>
              <p class="text-neutral-700 leading-relaxed font-light text-sm">
                {@detail["description"] || @detail["summary"]}
              </p>
            </div>
          <% end %>

          <%!-- Remediation --%>
          <%= if @detail["remediation"] do %>
            <div class="border-l-2 border-blue-500 pl-3 py-1 bg-blue-50/40 rounded-r">
              <h4 class="font-medium text-blue-900 uppercase tracking-wider text-[10px] mb-0.5">
                Recommended Remediation
              </h4>
              <p class="text-blue-950 leading-relaxed font-light">
                {@detail["remediation"]}
              </p>
            </div>
          <% end %>

          <%!-- Evidence Snippet --%>
          <%= if @detail["evidence"] do %>
            <div>
              <h4 class="font-medium text-neutral-500 uppercase tracking-wider text-[10px] mb-1">
                Observed Evidence
              </h4>
              <pre class="bg-neutral-900 text-neutral-100 p-3 rounded font-mono text-[11px] overflow-x-auto whitespace-pre-wrap break-all">{@detail["evidence"]}</pre>
            </div>
          <% end %>

          <%!-- CVE Specifics --%>
          <%= if @detail["cve_id"] || @detail["package"] do %>
            <div class="grid grid-cols-2 gap-3 bg-neutral-50 p-3 rounded border border-neutral-100">
              <div>
                <span class="text-neutral-400 block text-[10px] uppercase">Package Ecosystem</span>
                <span class="font-mono text-neutral-800 font-medium">
                  {@detail["ecosystem"]}: {@detail["package"]}
                </span>
              </div>
              <div>
                <span class="text-neutral-400 block text-[10px] uppercase">Affected Version</span>
                <span class="font-mono text-neutral-800 font-medium">{@detail["version"]}</span>
              </div>
            </div>
          <% end %>

          <%!-- References --%>
          <%= if @detail["references"] && @detail["references"] != [] do %>
            <div>
              <h4 class="font-medium text-neutral-500 uppercase tracking-wider text-[10px] mb-2">
                Advisories & References
              </h4>
              <ul class="space-y-1.5">
                <%= for ref_url <- @detail["references"] do %>
                  <li>
                    <a
                      href={ref_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="text-blue-600 hover:underline font-mono text-[11px] inline-flex items-center gap-1 break-all"
                    >
                      {ref_url}
                      <.icon
                        name="hero-arrow-top-right-on-square"
                        class="w-3 h-3 text-neutral-400 shrink-0"
                      />
                    </a>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>
        </div>

        <div class="p-4 border-t border-neutral-200 flex justify-end">
          <button
            phx-click="close_finding_detail"
            class="btn-line text-xs"
          >
            Close
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :latest_breach_scan, :map, default: nil
  attr :findings, :list, default: []
  attr :domain, :map, required: true

  defp breach_intelligence_tab(assigns) do
    raw_stats =
      if assigns.latest_breach_scan && assigns.latest_breach_scan.raw_output do
        case Jason.decode(assigns.latest_breach_scan.raw_output) do
          {:ok, stats} -> stats
          _ -> %{}
        end
      else
        %{}
      end

    assigns = assign(assigns, :stats, raw_stats)

    ~H"""
    <div class="space-y-6">
      <div class="card-line p-6">
        <div class="flex items-start justify-between gap-4 mb-4">
          <div>
            <h3 class="text-base font-normal text-neutral-900">
              Dark Web Infostealer & Compromised Credential Intelligence
            </h3>
            <p class="text-xs text-neutral-500 font-light mt-1">
              Active infostealer malware logs (RedLine, Lumma, Vidar, Racoon) collected from cybercriminal networks via Hudson Rock OSINT.
            </p>
          </div>
          <%= if @latest_breach_scan do %>
            <span class="text-[10px] font-mono text-neutral-400">
              Scanned {Calendar.strftime(
                @latest_breach_scan.completed_at || @latest_breach_scan.inserted_at,
                "%Y-%m-%d %H:%M"
              )}
            </span>
          <% end %>
        </div>

        <%= if @stats != %{} do %>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
            <div class="bg-neutral-50 rounded-lg p-4 border border-neutral-100">
              <span class="text-[10px] uppercase tracking-wider text-neutral-500 block mb-1">
                Heat Status
              </span>
              <div class="flex items-center gap-2">
                <span class={[
                  "text-xs font-medium px-2 py-0.5 rounded border inline-flex items-center gap-1",
                  @stats["heat"] == "hot" && "bg-red-50 text-red-700 border-red-200",
                  @stats["heat"] == "recent" && "bg-orange-50 text-orange-700 border-orange-200",
                  @stats["heat"] == "historical" &&
                    "bg-neutral-100 text-neutral-700 border-neutral-200",
                  @stats["heat"] == "clean" && "bg-green-50 text-green-700 border-green-200"
                ]}>
                  <%= if @stats["heat"] == "hot" do %>
                    <.icon name="hero-fire" class="w-3.5 h-3.5 text-red-600" />
                  <% end %>
                  {@stats["heat_label"] || String.upcase(@stats["heat"] || "clean")}
                </span>
              </div>
            </div>

            <div class="bg-neutral-50 rounded-lg p-4 border border-neutral-100">
              <span class="text-[10px] uppercase tracking-wider text-neutral-500 block mb-1">
                Compromised Employees
              </span>
              <span class="text-2xl font-light text-neutral-900 font-mono">
                {@stats["employees"] || 0}
              </span>
              <span class="text-[10px] text-neutral-400 block mt-1">
                Direct corporate email addresses in malware logs
              </span>
            </div>

            <div class="bg-neutral-50 rounded-lg p-4 border border-neutral-100">
              <span class="text-[10px] uppercase tracking-wider text-neutral-500 block mb-1">
                Compromised Users / Clients
              </span>
              <span class="text-2xl font-light text-neutral-900 font-mono">
                {@stats["users"] || 0}
              </span>
              <span class="text-[10px] text-neutral-400 block mt-1">
                Clients whose machines were infected with stealers
              </span>
            </div>
          </div>

          <%= if @stats["stealer_families"] && @stats["stealer_families"] != [] do %>
            <div class="mb-4">
              <h4 class="text-xs font-medium text-neutral-700 mb-2">
                Detected Infostealer Malware Families:
              </h4>
              <div class="flex flex-wrap gap-1.5">
                <%= for family <- @stats["stealer_families"] do %>
                  <span class="bg-red-50 text-red-700 border border-red-100 px-2 py-0.5 rounded text-xs font-mono">
                    {family}
                  </span>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @stats["targeted_urls"] && @stats["targeted_urls"] != [] do %>
            <div>
              <h4 class="text-xs font-medium text-neutral-700 mb-2">
                Compromised Corporate Portals & URLs:
              </h4>
              <div class="space-y-1">
                <%= for url <- @stats["targeted_urls"] do %>
                  <div class="bg-neutral-50 border border-neutral-100 px-3 py-1.5 rounded font-mono text-xs text-neutral-700 truncate">
                    {url}
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        <% else %>
          <div class="py-8 text-center text-neutral-400 font-light text-xs">
            No dark web intelligence scan has been run yet for {@domain.name}. Click "Check Dark Web Leaks" above to check.
          </div>
        <% end %>
      </div>

      <%!-- Findings list for breach scan --%>
      <%= if @findings != [] do %>
        <div class="space-y-3">
          <h4 class="text-xs font-medium uppercase tracking-wider text-neutral-500">
            Breach Findings ({length(@findings)})
          </h4>
          <%= for finding <- @findings do %>
            <.finding_card finding={finding} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :scans, :list, default: []

  defp scan_history_tab(assigns) do
    ~H"""
    <div class="card-line overflow-hidden">
      <table class="w-full text-xs text-left">
        <thead class="bg-neutral-50 text-neutral-500 uppercase tracking-wider text-[10px] border-b border-neutral-200">
          <tr>
            <th class="py-3 px-4">Tool</th>
            <th class="py-3 px-4">Status</th>
            <th class="py-3 px-4">Findings</th>
            <th class="py-3 px-4">Started At</th>
            <th class="py-3 px-4">Summary</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-neutral-100 font-light">
          <%= for scan <- @scans do %>
            <tr class="hover:bg-neutral-50/50">
              <td class="py-3 px-4 font-mono font-medium text-neutral-900">
                {scan_tool_title(scan.tool)}
              </td>
              <td class="py-3 px-4">
                <span class={[
                  "text-[10px] uppercase tracking-wider px-2 py-0.5 rounded font-semibold",
                  scan.status == "completed" && "bg-green-50 text-green-700",
                  scan.status == "running" && "bg-yellow-50 text-yellow-700",
                  scan.status == "failed" && "bg-red-50 text-red-700"
                ]}>
                  {scan.status}
                </span>
              </td>
              <td class="py-3 px-4 font-mono font-medium">
                {if Ecto.assoc_loaded?(scan.findings), do: length(scan.findings), else: "—"}
              </td>
              <td class="py-3 px-4 text-neutral-500 font-mono text-[11px]">
                {if scan.started_at,
                  do: Calendar.strftime(scan.started_at, "%Y-%m-%d %H:%M:%S"),
                  else: "—"}
              </td>
              <td class="py-3 px-4 text-neutral-600 truncate max-w-xs">
                {scan.summary || scan.error_message || "—"}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  # ─── Data Helpers ──────────────────────────────────────────────────────────

  defp load_report_data(socket, domain_id) do
    latest_sec = SecurityScans.latest_security_scan(domain_id)
    latest_breach = SecurityScans.latest_breach_scan(domain_id)
    running = SecurityScans.running_scan(domain_id)
    past_scans = SecurityScans.list_scans_for_domain(domain_id)

    all_findings = SecurityScans.list_all_active_findings_for_domain(domain_id)

    cve_findings = Enum.filter(all_findings, &cve_finding?/1)
    exposure_findings = Enum.filter(all_findings, &exposure_finding?/1)
    tls_header_findings = Enum.filter(all_findings, &tls_header_finding?/1)
    port_findings = Enum.filter(all_findings, &port_finding?/1)
    breach_findings = Enum.filter(all_findings, &breach_finding?/1)

    severity_counts = SecurityScans.severity_counts_for_domain(domain_id)

    socket
    |> assign(:latest_security_scan, latest_sec)
    |> assign(:latest_breach_scan, latest_breach)
    |> assign(:running_scan, running)
    |> assign(:past_scans, past_scans)
    |> assign(:all_findings, all_findings)
    |> assign(:cve_findings, cve_findings)
    |> assign(:exposure_findings, exposure_findings)
    |> assign(:tls_header_findings, tls_header_findings)
    |> assign(:port_findings, port_findings)
    |> assign(:breach_findings, breach_findings)
    |> assign(:severity_counts, severity_counts)
  end

  defp current_tab_findings(assigns) do
    case assigns.active_tab do
      :cves -> assigns.cve_findings
      :exposures -> assigns.exposure_findings
      :tls_headers -> assigns.tls_header_findings
      :ports -> assigns.port_findings
      :breach -> assigns.breach_findings
      _ -> assigns.all_findings
    end
  end

  defp filtered_findings(assigns) do
    findings = current_tab_findings(assigns)
    query = String.downcase(String.trim(assigns.search_query))
    severity = assigns.selected_severity

    findings
    |> Enum.filter(fn f ->
      # Severity filter
      severity_match = is_nil(severity) or f.severity == severity

      # Search filter
      query_match =
        if query == "" do
          true
        else
          title_match = String.contains?(String.downcase(f.title || ""), query)
          target_match = String.contains?(String.downcase(f.target || ""), query)

          detail_match =
            if is_map(f.detail) do
              String.contains?(String.downcase(inspect(f.detail)), query)
            else
              false
            end

          title_match or target_match or detail_match
        end

      severity_match and query_match
    end)
  end

  defp count_by_severity(findings, severity) do
    Enum.count(findings, &(&1.severity == severity))
  end

  defp cve_finding?(finding) do
    detail = finding.detail || %{}

    detail["source"] in ["osv_cve", "repo_sca"] or
      String.contains?(finding.title, "CVE-") or
      String.contains?(finding.title, "GHSA-")
  end

  defp exposure_finding?(finding) do
    detail = finding.detail || %{}

    detail["source"] == "curated_probes" or
      detail["category"] in [
        "secrets",
        "source_leak",
        "actuator",
        "debug_panel",
        "backup",
        "logs",
        "infrastructure",
        "api_docs",
        "metadata",
        "admin_panel"
      ]
  end

  defp tls_header_finding?(finding) do
    detail = finding.detail || %{}

    detail["source"] in ["tls_audit", "headers_audit"] or
      detail["header"] != nil or
      detail["protocol"] != nil
  end

  defp port_finding?(finding) do
    detail = finding.detail || %{}

    detail["source"] == "port_probe" or
      detail["port"] != nil or
      (String.contains?(finding.title, "Exposed ") and detail["service"] != nil)
  end

  defp breach_finding?(finding) do
    detail = finding.detail || %{}

    detail["source"] == "breach_lookup" or
      detail["heat"] != nil or
      detail["stealer_families"] != nil
  end

  defp category_label(finding) do
    detail = finding.detail || %{}

    cond do
      detail["source"] == "repo_sca" ->
        "Repo SCA"

      cve_finding?(finding) ->
        "CVE"

      exposure_finding?(finding) ->
        detail["category"] || "Exposure"

      tls_header_finding?(finding) ->
        if detail["source"] == "tls_audit", do: "TLS", else: "Header"

      port_finding?(finding) ->
        "Port"

      breach_finding?(finding) ->
        "Dark Web"

      true ->
        nil
    end
  end

  defp scan_tool_title("light_scan"), do: "Lightweight Scan"
  defp scan_tool_title("repo_sca"), do: "Repository Dependency Scan (SCA)"
  defp scan_tool_title("security_scan"), do: "Deep Security Scan"
  defp scan_tool_title("breach_lookup"), do: "Dark Web Leak Scan"
  defp scan_tool_title("nuclei"), do: "Nuclei Scanner"
  defp scan_tool_title("naabu"), do: "Naabu Port Scanner"
  defp scan_tool_title(other), do: to_string(other)
end
