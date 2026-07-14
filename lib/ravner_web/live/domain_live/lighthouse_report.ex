defmodule RavnerWeb.DomainLive.LighthouseReport do
  @moduledoc """
  Lighthouse PageSpeed report for a domain.
  Shows performance, accessibility, best practices, and SEO scores with key metrics.
  """
  use RavnerWeb, :live_view

  alias Ravner.Domains
  alias Ravner.Lighthouse

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    domain = Domains.get_domain_with_preloads!(id)
    scan = Lighthouse.latest_scan(domain.id)

    audits =
      if scan && scan.results_raw do
        scan.results_raw["audits"] || %{}
      else
        %{}
      end

    # Split audits into opportunities (have savings) and diagnostics
    {opportunities, diagnostics} = split_audits(audits)

    {:ok,
     socket
     |> assign(:page_title, "Lighthouse — #{domain.name}")
     |> assign(:domain, domain)
     |> assign(:scan, scan)
     |> assign(:opportunities, opportunities)
     |> assign(:diagnostics, diagnostics)
     |> assign(:show_section, nil)}
  end

  @impl true
  def handle_event("toggle_section", %{"section" => section}, socket) do
    current = socket.assigns.show_section
    new = if current == section, do: nil, else: section
    {:noreply, assign(socket, :show_section, new)}
  end

  def handle_event("rescan", _params, socket) do
    if socket.assigns.current_scope.user.role in [:admin, :editor] do
      domain = socket.assigns.domain

      if Lighthouse.scannable?(domain) do
        %{domain_id: domain.id}
        |> Ravner.Workers.LighthouseScanWorker.new()
        |> Oban.insert()

        {:noreply, put_flash(socket, :info, "Lighthouse scan queued.")}
      else
        {:noreply, put_flash(socket, :error, "Domain not eligible for scan.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Permission denied.")}
    end
  end

  # --- Helpers ---

  defp split_audits(audits) do
    items =
      audits
      |> Enum.map(fn {_k, v} -> v end)
      |> Enum.filter(&is_map/1)
      |> Enum.sort_by(fn a -> a["score"] || 1 end)

    opportunities = Enum.filter(items, &(Map.has_key?(&1, "numericValue") && &1["score"] != nil && &1["score"] < 1))
    diagnostics = Enum.filter(items, &(!Map.has_key?(&1, "numericValue") && &1["score"] != nil && &1["score"] < 1))

    {Enum.take(opportunities, 10), Enum.take(diagnostics, 10)}
  end

  defp score_ring_color(nil), do: "#d4d4d4"
  defp score_ring_color(s) when s >= 90, do: "#16a34a"
  defp score_ring_color(s) when s >= 50, do: "#d97706"
  defp score_ring_color(_), do: "#dc2626"

  defp format_ms(nil), do: "—"
  defp format_ms(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_ms(ms), do: "#{ms}ms"

  defp format_cls(nil), do: "—"
  defp format_cls(cls), do: Float.round(cls, 3) |> to_string()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-5xl mx-auto px-6 py-8">
        <%!-- Breadcrumb --%>
        <nav class="flex items-center gap-1 text-xs font-light text-neutral-500 mb-4">
          <.link navigate={~p"/domains"} class="hover:text-neutral-900 transition-colors">
            Domains
          </.link>
          <.icon name="hero-chevron-right" class="w-3 h-3" />
          <.link navigate={~p"/domains/#{@domain.id}"} class="hover:text-neutral-900 transition-colors">
            {@domain.name}
          </.link>
          <.icon name="hero-chevron-right" class="w-3 h-3" />
          <span class="text-neutral-900">Lighthouse</span>
        </nav>

        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-light tracking-tight">PageSpeed Report</h1>
            <p class="text-sm font-light text-neutral-500 mt-1">
              Google Lighthouse · Performance & SEO audit
            </p>
          </div>
          <button
            id="rescan-lighthouse-btn"
            phx-click="rescan"
            disabled={is_nil(@current_scope) || @current_scope.user.role not in [:admin, :editor]}
            class="text-xs font-light px-3 py-1.5 border border-neutral-300 text-neutral-600 hover:border-neutral-900 hover:text-neutral-900 transition-colors"
          >
            Re-scan
          </button>
        </div>

        <%= if is_nil(@scan) do %>
          <div class="card-line py-12 text-center">
            <p class="text-sm font-light text-neutral-400">
              No Lighthouse scan results yet. Run a scan from the domain page.
            </p>
          </div>
        <% else %>
          <%!-- Score gauges --%>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-6 mb-10">
            <%= for {label, score} <- [{"Performance", @scan.performance_score}, {"Accessibility", @scan.accessibility_score}, {"Best Practices", @scan.best_practices_score}, {"SEO", @scan.seo_score}] do %>
              <div class="flex flex-col items-center">
                <div class="relative w-20 h-20 mb-3">
                  <svg viewBox="0 0 36 36" class="w-full h-full -rotate-90">
                    <path
                      d="M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831"
                      fill="none"
                      stroke="#e5e5e5"
                      stroke-width="2.5"
                    />
                    <path
                      d="M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831"
                      fill="none"
                      stroke={score_ring_color(score)}
                      stroke-width="2.5"
                      stroke-dasharray={if(score, do: "#{score}, 100", else: "0, 100")}
                      stroke-linecap="round"
                    />
                  </svg>
                  <div class="absolute inset-0 flex items-center justify-center">
                    <span class="text-lg font-light">{score || "—"}</span>
                  </div>
                </div>
                <span class="text-xs font-light text-neutral-500">{label}</span>
              </div>
            <% end %>
          </div>

          <%!-- Key metrics --%>
          <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-10">
            <div class="border border-neutral-200 p-4 text-center dark:border-neutral-700">
              <div class="text-lg font-light">{format_ms(@scan.fcp_ms)}</div>
              <div class="text-[10px] uppercase tracking-wide text-neutral-400 mt-1">FCP</div>
            </div>
            <div class="border border-neutral-200 p-4 text-center dark:border-neutral-700">
              <div class="text-lg font-light">{format_ms(@scan.lcp_ms)}</div>
              <div class="text-[10px] uppercase tracking-wide text-neutral-400 mt-1">LCP</div>
            </div>
            <div class="border border-neutral-200 p-4 text-center dark:border-neutral-700">
              <div class="text-lg font-light">{format_ms(@scan.tbt_ms)}</div>
              <div class="text-[10px] uppercase tracking-wide text-neutral-400 mt-1">TBT</div>
            </div>
            <div class="border border-neutral-200 p-4 text-center dark:border-neutral-700">
              <div class="text-lg font-light">{format_cls(@scan.cls)}</div>
              <div class="text-[10px] uppercase tracking-wide text-neutral-400 mt-1">CLS</div>
            </div>
            <div class="border border-neutral-200 p-4 text-center dark:border-neutral-700">
              <div class="text-lg font-light">{format_ms(@scan.speed_index_ms)}</div>
              <div class="text-[10px] uppercase tracking-wide text-neutral-400 mt-1">Speed Index</div>
            </div>
          </div>

          <%!-- Scan metadata --%>
          <div class="flex items-center gap-4 text-xs font-light text-neutral-400 mb-6">
            <span>URL: {@scan.url}</span>
            <span>·</span>
            <span>Scanned: {Calendar.strftime(@scan.completed_at, "%Y-%m-%d %H:%M")}</span>
          </div>

          <%!-- Opportunities --%>
          <%= if @opportunities != [] do %>
            <div class="card-line mb-4">
              <button
                phx-click="toggle_section"
                phx-value-section="opportunities"
                class="w-full flex items-center justify-between py-2 text-left"
              >
                <h2 class="text-sm font-normal">Opportunities</h2>
                <.icon
                  name="hero-chevron-down"
                  class={["w-4 h-4 text-neutral-400 transition-transform", @show_section == "opportunities" && "rotate-180"]}
                />
              </button>
              <%= if @show_section == "opportunities" do %>
                <div class="mt-3 border-t border-neutral-100 pt-3 space-y-2">
                  <%= for audit <- @opportunities do %>
                    <div class="flex items-center justify-between py-1.5 text-sm">
                      <span class="font-light text-neutral-700">{audit["title"]}</span>
                      <span :if={audit["displayValue"]} class="text-xs text-neutral-400 shrink-0 ml-4">
                        {audit["displayValue"]}
                      </span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Diagnostics --%>
          <%= if @diagnostics != [] do %>
            <div class="card-line">
              <button
                phx-click="toggle_section"
                phx-value-section="diagnostics"
                class="w-full flex items-center justify-between py-2 text-left"
              >
                <h2 class="text-sm font-normal">Diagnostics</h2>
                <.icon
                  name="hero-chevron-down"
                  class={["w-4 h-4 text-neutral-400 transition-transform", @show_section == "diagnostics" && "rotate-180"]}
                />
              </button>
              <%= if @show_section == "diagnostics" do %>
                <div class="mt-3 border-t border-neutral-100 pt-3 space-y-2">
                  <%= for audit <- @diagnostics do %>
                    <div class="py-1.5 text-sm">
                      <span class="font-light text-neutral-700">{audit["title"]}</span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
