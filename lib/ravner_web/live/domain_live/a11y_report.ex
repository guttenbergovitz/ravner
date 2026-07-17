defmodule RavnerWeb.DomainLive.A11yReport do
  @moduledoc """
  Accessibility scan report for a domain.
  Shows WCAG 2.1 AA compliance status grouped by principle.
  """
  use RavnerWeb, :live_view

  alias Ravner.A11y
  alias Ravner.Domains

  # WCAG 2.1 principles for grouping
  @principles %{
    "Principle1" => %{name: "Perceivable", number: 1},
    "Principle2" => %{name: "Operable", number: 2},
    "Principle3" => %{name: "Understandable", number: 3},
    "Principle4" => %{name: "Robust", number: 4}
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    domain = Domains.get_domain_with_preloads!(id)
    scan = A11y.latest_scan(domain.id)

    issues = if scan, do: scan.results_raw["issues"] || [], else: []
    grouped = group_by_principle(issues)

    expanded =
      grouped
      |> Enum.filter(&(&1.count > 0))
      |> Enum.map(& &1.key)
      |> MapSet.new()

    {:ok,
     socket
     |> assign(:page_title, "A11y Report — #{domain.name}")
     |> assign(:domain, domain)
     |> assign(:scan, scan)
     |> assign(:issues, issues)
     |> assign(:grouped, grouped)
     |> assign(:expanded, expanded)}
  end

  @impl true
  def handle_event("toggle_principle", %{"principle" => key}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, key) do
        MapSet.delete(socket.assigns.expanded, key)
      else
        MapSet.put(socket.assigns.expanded, key)
      end

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("rescan", _params, socket) do
    if socket.assigns.current_scope.user.role in [:admin, :editor] do
      domain = socket.assigns.domain

      if A11y.scannable?(domain) do
        %{domain_id: domain.id}
        |> Ravner.Workers.A11yScanWorker.new()
        |> Oban.insert()

        {:noreply, put_flash(socket, :info, "Accessibility scan queued.")}
      else
        {:noreply, put_flash(socket, :error, "Domain not eligible for scan.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Permission denied.")}
    end
  end

  # --- Helpers ---

  defp group_by_principle(issues) do
    issues
    |> Enum.group_by(fn issue ->
      case Regex.run(~r/WCAG2AA\.(Principle\d)/, issue["code"] || "") do
        [_, principle] -> principle
        _ -> "Other"
      end
    end)
    |> Enum.map(fn {key, items} ->
      meta = Map.get(@principles, key, %{name: key, number: 99})
      %{key: key, name: meta.name, number: meta.number, issues: items, count: length(items)}
    end)
    |> Enum.sort_by(& &1.number)
  end

  defp guideline_from_code(code) do
    case Regex.run(~r/Guideline(\d+_\d+)/, code || "") do
      [_, g] -> String.replace(g, "_", ".")
      _ -> nil
    end
  end

  defp eaa_compliant?(scan) do
    scan && scan.status == "completed" && scan.violations_count == 0
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-5xl mx-auto px-6 py-8">
        <%!-- Header --%>
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
          <span class="text-neutral-900">Accessibility</span>
        </nav>

        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-light tracking-tight">Accessibility Report</h1>
            <p class="text-sm font-light text-neutral-500 mt-1">
              WCAG 2.1 AA · EN 301 549 · European Accessibility Act
            </p>
          </div>

          <div class="flex items-center gap-4">
            <%!-- EAA Compliance badge --%>
            <%= if @scan do %>
              <span class={[
                "inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium border",
                eaa_compliant?(@scan) && "bg-green-50 text-green-700 border-green-200",
                !eaa_compliant?(@scan) && "bg-red-50 text-red-700 border-red-200"
              ]}>
                <%= if eaa_compliant?(@scan) do %>
                  <.icon name="hero-check-circle" class="w-4 h-4" /> EAA Compliant
                <% else %>
                  <.icon name="hero-x-circle" class="w-4 h-4" /> EAA Non-Compliant
                <% end %>
              </span>
            <% end %>

            <button
              id="rescan-a11y-btn"
              phx-click="rescan"
              disabled={is_nil(@current_scope) || @current_scope.user.role not in [:admin, :editor]}
              class="text-xs font-light px-3 py-1.5 border border-neutral-300 text-neutral-600 hover:border-neutral-900 hover:text-neutral-900 transition-colors"
            >
              Re-scan
            </button>
          </div>
        </div>

        <%= if is_nil(@scan) do %>
          <div class="card-line py-12 text-center">
            <p class="text-sm font-light text-neutral-400">
              No accessibility scan results yet. Run a scan from the domain page.
            </p>
          </div>
        <% else %>
          <%!-- Summary --%>
          <div class="grid grid-cols-4 gap-4 mb-8">
            <div class="card-line text-center py-4">
              <div class="text-2xl font-light">{@scan.violations_count || 0}</div>
              <div class="text-[10px] uppercase tracking-wide text-neutral-500 mt-1">
                Violations
              </div>
            </div>
            <%= for group <- @grouped do %>
              <div class="card-line text-center py-4">
                <div class={[
                  "text-2xl font-light",
                  group.count == 0 && "text-green-600",
                  group.count > 0 && group.count <= 5 && "text-yellow-600",
                  group.count > 5 && "text-red-600"
                ]}>
                  {group.count}
                </div>
                <div class="text-[10px] uppercase tracking-wide text-neutral-500 mt-1">
                  {group.number}. {group.name}
                </div>
              </div>
            <% end %>
          </div>

          <%!-- Scan metadata --%>
          <div class="flex items-center gap-4 text-xs font-light text-neutral-400 mb-6">
            <span>URL: {@scan.url}</span>
            <span>·</span>
            <span>Standard: {@scan.standard}</span>
            <span>·</span>
            <span>Scanned: {Calendar.strftime(@scan.completed_at, "%Y-%m-%d %H:%M")}</span>
          </div>

          <%!-- Issues grouped by principle --%>
          <div class="space-y-4">
            <%= for group <- @grouped do %>
              <div class="card-line" id={"principle-#{group.key}"}>
                <button
                  phx-click="toggle_principle"
                  phx-value-principle={group.key}
                  class="w-full flex items-center justify-between py-2 text-left"
                >
                  <div class="flex items-center gap-3">
                    <span class={[
                      "w-7 h-7 flex items-center justify-center text-xs font-medium rounded-full",
                      group.count == 0 && "bg-green-100 text-green-700",
                      group.count > 0 && "bg-red-100 text-red-700"
                    ]}>
                      {group.count}
                    </span>
                    <div>
                      <span class="text-sm font-normal">
                        Principle {group.number}: {group.name}
                      </span>
                    </div>
                  </div>
                  <.icon
                    name="hero-chevron-down"
                    class={[
                      "w-4 h-4 text-neutral-400 transition-transform",
                      MapSet.member?(@expanded, group.key) && "rotate-180"
                    ]}
                  />
                </button>

                <%= if MapSet.member?(@expanded, group.key) && group.count > 0 do %>
                  <div class="mt-4 border-t border-neutral-100 pt-4 space-y-3">
                    <%= for issue <- group.issues do %>
                      <div class="text-sm border-l-2 border-red-200 pl-3 py-1">
                        <p class="font-light text-neutral-800">{issue["message"]}</p>
                        <div class="flex flex-wrap items-center gap-3 mt-1.5 text-[10px] text-neutral-400">
                          <span class="font-mono bg-neutral-50 px-1.5 py-0.5 border border-neutral-100">
                            {issue["code"]}
                          </span>
                          <%= if guideline_from_code(issue["code"]) do %>
                            <span>Guideline {guideline_from_code(issue["code"])}</span>
                          <% end %>
                          <span class="truncate max-w-[300px]" title={issue["selector"]}>
                            {issue["selector"]}
                          </span>
                        </div>
                        <%= if issue["context"] do %>
                          <pre
                            class="mt-1.5 text-[10px] font-mono text-neutral-500 bg-neutral-50 border border-neutral-100 p-2 overflow-x-auto max-h-16"
                            phx-no-curly-interpolation
                          >{issue["context"]}</pre>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
