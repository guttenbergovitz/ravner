defmodule RavnerWeb.DomainLive.ScanQualityPanels do
  use RavnerWeb, :html

  attr :domain, :map, required: true
  attr :a11y_scannable?, :boolean, required: true
  attr :scanning, :boolean, required: true
  attr :a11y_running?, :boolean, required: true
  attr :can_scan?, :boolean, required: true
  attr :a11y_scan, :any, required: true
  attr :lighthouse_scan, :any, required: true
  attr :lighthouse_running?, :boolean, required: true
  attr :myself, :any, required: true

  def scan_quality_panels(assigns) do
    ~H"""
    <%!-- Accessibility Card --%>
    <div :if={@a11y_scannable?} class="card-line" id="a11y-panel">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-sm font-normal tracking-wide uppercase">Accessibility</h2>
        <button
          type="button"
          id="scan-a11y-btn"
          phx-click="scan_a11y"
          phx-target={@myself}
          disabled={@a11y_running? || @scanning || !@can_scan?}
          title={if !@can_scan?, do: "Insufficient permissions to run scans"}
          class={[
            "text-xs font-light px-2.5 py-1 border transition-colors",
            (@a11y_running? || @scanning || !@can_scan?) &&
              "opacity-50 cursor-not-allowed border-neutral-200 text-neutral-400",
            !(@a11y_running? || @scanning || !@can_scan?) &&
              "border-neutral-300 text-neutral-600 hover:border-neutral-900 hover:text-neutral-900"
          ]}
        >
          <%= if @a11y_running? do %>
            <span class="inline-flex items-center gap-1">
              <span class="w-3 h-3 border border-current border-t-transparent rounded-full animate-spin">
              </span>
              Scanning…
            </span>
          <% else %>
            Run WCAG scan
          <% end %>
        </button>
      </div>

      <%= if @a11y_scan do %>
        <div class="space-y-3">
          <div class="flex items-center gap-3">
            <span class={[
              "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
              @a11y_scan.violations_count == 0 && "bg-green-100 text-green-700",
              @a11y_scan.violations_count > 0 && @a11y_scan.violations_count <= 5 &&
                "bg-yellow-100 text-yellow-700",
              @a11y_scan.violations_count > 5 && "bg-red-100 text-red-700"
            ]}>
              {@a11y_scan.violations_count || 0} violations
            </span>
            <span
              :if={@a11y_scan.warnings_count && @a11y_scan.warnings_count > 0}
              class="text-xs text-neutral-400"
            >
              {@a11y_scan.warnings_count} warnings
            </span>
          </div>

          <div :if={@a11y_scan.completed_at} class="text-[10px] text-neutral-400">
            Scanned {Calendar.strftime(@a11y_scan.completed_at, "%Y-%m-%d %H:%M")} · {@a11y_scan.standard}
          </div>

          <.link
            navigate={~p"/domains/#{@domain.id}/a11y"}
            class="inline-flex items-center gap-1 text-xs font-light text-neutral-500 hover:text-neutral-900 transition-colors"
          >
            View full report <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        </div>
      <% else %>
        <p class="text-xs font-light text-neutral-400">No scan results yet.</p>
      <% end %>
    </div>

    <%!-- Lighthouse / PageSpeed Card --%>
    <div :if={@a11y_scannable?} class="card-line" id="lighthouse-panel">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-sm font-normal tracking-wide uppercase">PageSpeed</h2>
        <button
          type="button"
          id="scan-lighthouse-btn"
          phx-click="scan_lighthouse"
          phx-target={@myself}
          disabled={@lighthouse_running? || @scanning || !@can_scan?}
          title={if !@can_scan?, do: "Insufficient permissions to run scans"}
          class={[
            "text-xs font-light px-2.5 py-1 border transition-colors",
            (@lighthouse_running? || @scanning || !@can_scan?) &&
              "opacity-50 cursor-not-allowed border-neutral-200 text-neutral-400",
            !(@lighthouse_running? || @scanning || !@can_scan?) &&
              "border-neutral-300 text-neutral-600 hover:border-neutral-900 hover:text-neutral-900"
          ]}
        >
          <%= if @lighthouse_running? do %>
            <span class="inline-flex items-center gap-1">
              <span class="w-3 h-3 border border-current border-t-transparent rounded-full animate-spin">
              </span>
              Scanning…
            </span>
          <% else %>
            Run Lighthouse
          <% end %>
        </button>
      </div>

      <%= if @lighthouse_scan do %>
        <div class="space-y-3">
          <div class="grid grid-cols-4 gap-2 text-center">
            <div>
              <div class={[
                "text-lg font-light",
                @lighthouse_scan.performance_score && @lighthouse_scan.performance_score >= 90 &&
                  "text-green-600",
                @lighthouse_scan.performance_score && @lighthouse_scan.performance_score >= 50 &&
                  @lighthouse_scan.performance_score < 90 && "text-amber-600",
                @lighthouse_scan.performance_score && @lighthouse_scan.performance_score < 50 &&
                  "text-red-600",
                is_nil(@lighthouse_scan.performance_score) && "text-neutral-300"
              ]}>
                {@lighthouse_scan.performance_score || "—"}
              </div>
              <div class="text-[9px] uppercase tracking-wide text-neutral-400">Perf</div>
            </div>
            <div>
              <div class="text-lg font-light text-neutral-600">
                {@lighthouse_scan.seo_score || "—"}
              </div>
              <div class="text-[9px] uppercase tracking-wide text-neutral-400">SEO</div>
            </div>
            <div>
              <div class="text-lg font-light text-neutral-600">
                {@lighthouse_scan.best_practices_score || "—"}
              </div>
              <div class="text-[9px] uppercase tracking-wide text-neutral-400">BP</div>
            </div>
            <div>
              <div class="text-lg font-light text-neutral-600">
                {@lighthouse_scan.accessibility_score || "—"}
              </div>
              <div class="text-[9px] uppercase tracking-wide text-neutral-400">A11y</div>
            </div>
          </div>

          <div :if={@lighthouse_scan.completed_at} class="text-[10px] text-neutral-400">
            Scanned {Calendar.strftime(@lighthouse_scan.completed_at, "%Y-%m-%d %H:%M")}
          </div>

          <.link
            navigate={~p"/domains/#{@domain.id}/lighthouse"}
            class="inline-flex items-center gap-1 text-xs font-light text-neutral-500 hover:text-neutral-900 transition-colors"
          >
            View full report <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        </div>
      <% else %>
        <p class="text-xs font-light text-neutral-400">No scan results yet.</p>
      <% end %>
    </div>
    """
  end
end
