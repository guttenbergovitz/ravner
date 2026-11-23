defmodule RavnerWeb.DomainLive.ScanPanel do
  @moduledoc """
  LiveComponent for domain scan controls: Discovery scans, Accessibility WCAG scans,
  Lighthouse performance audits, and automation scheduling settings.
  """
  use RavnerWeb, :live_component

  alias Ravner.Domains.Domain
  alias RavnerWeb.DomainLive.ScanCoordinator
  import RavnerWeb.DomainLive.ScanSchedule
  import RavnerWeb.DomainLive.ScanQualityPanels

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    scannable? = Domain.scannable?(assigns.domain)

    socket =
      socket
      |> assign(assigns)
      |> assign(:scannable?, scannable?)

    {:ok, socket}
  end

  @impl true
  def handle_event("scan_all", _params, socket) do
    ScanCoordinator.handle_scan_all(socket)
  end

  @impl true
  def handle_event("scan_deep_tech", _params, socket) do
    ScanCoordinator.handle_scan_deep_tech(socket)
  end

  @impl true
  def handle_event("scan_dnsx", _params, socket) do
    ScanCoordinator.handle_scan_dnsx(socket)
  end

  @impl true
  def handle_event("scan_httpx", _params, socket) do
    ScanCoordinator.handle_scan_httpx(socket)
  end

  @impl true
  def handle_event("scan_rdap", _params, socket) do
    ScanCoordinator.handle_scan_rdap(socket)
  end

  @impl true
  def handle_event("scan_subdomains", _params, socket) do
    ScanCoordinator.handle_scan_subdomains(socket)
  end

  @impl true
  def handle_event("scan_a11y", _params, socket) do
    ScanCoordinator.handle_scan_a11y(socket)
  end

  @impl true
  def handle_event("scan_lighthouse", _params, socket) do
    ScanCoordinator.handle_scan_lighthouse(socket)
  end

  @impl true
  def handle_event("update_scheduling", params, socket) do
    ScanCoordinator.handle_update_scheduling(socket, params, fn s ->
      # Notify parent to reload domain
      send(
        self(),
        {:domain_updated, Ravner.Domains.get_domain_with_preloads!(s.assigns.domain.id)}
      )

      s
    end)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :scan_disabled?,
        assigns.scanning || !is_nil(assigns.running_security_scan) || !assigns.can_scan? ||
          !assigns.scannable?
      )

    ~H"""
    <div id="scan-panel-component" class="space-y-6">
      <%!-- Discovery Action Card --%>
      <div class="card-line" id="discovery-scan-panel">
        <div class="flex items-center justify-between mb-6">
          <h2 class="text-sm font-normal tracking-wide uppercase">Discovery</h2>
          <span
            :if={!@scannable?}
            class="text-[10px] uppercase tracking-wider px-2 py-0.5 rounded bg-neutral-100 text-neutral-500 dark:bg-neutral-800 dark:text-neutral-400"
            title={"Scanning is disabled for #{@domain.lifecycle_state} domains"}
          >
            {@domain.lifecycle_state |> Atom.to_string() |> String.replace("_", " ")}
          </span>
        </div>
        <div class="space-y-4">
          <%!-- Primary Actions --%>
          <div class="space-y-2">
            <button
              type="button"
              phx-click="scan_all"
              phx-target={@myself}
              disabled={@scan_disabled?}
              title={scan_disabled_title(@can_scan?, @scannable?, @domain.lifecycle_state)}
              class={[
                "w-full flex items-center justify-center gap-2 px-4 py-2.5 text-xs font-normal tracking-wide uppercase border transition-colors",
                @scan_disabled? &&
                  "opacity-50 cursor-not-allowed border-neutral-200 text-neutral-400",
                !@scan_disabled? &&
                  "border-neutral-900 text-neutral-900 hover:bg-neutral-900 hover:text-white"
              ]}
            >
              <%= if @scanning && @active_scan_kind == :all do %>
                <span class="w-3.5 h-3.5 border border-current border-t-transparent rounded-full animate-spin shrink-0">
                </span>
                Scanning<span class="animate-pulse">…</span>
              <% else %>
                <.icon name="hero-bolt" class="w-3.5 h-3.5" /> Run all scans
              <% end %>
            </button>

            <%= if @domain.technical_status == :redirect do %>
              <p class="text-[10px] text-neutral-400 italic text-center py-2">
                Deep scans unavailable — domain redirects externally
              </p>
            <% else %>
              <button
                type="button"
                id="scan-deep-tech"
                phx-click="scan_deep_tech"
                phx-target={@myself}
                disabled={@scan_disabled?}
                title={scan_disabled_title(@can_scan?, @scannable?, @domain.lifecycle_state)}
                class={[
                  "w-full flex items-center justify-center gap-2 px-4 py-2.5 text-xs font-normal tracking-wide uppercase border transition-colors",
                  @scan_disabled? &&
                    "opacity-50 cursor-not-allowed border-neutral-200 text-neutral-400",
                  !@scan_disabled? &&
                    "border-neutral-300 text-neutral-600 hover:border-neutral-900 hover:text-neutral-900"
                ]}
              >
                <%= if @scanning && @active_scan_kind == :deep_tech do %>
                  <span class="w-3.5 h-3.5 border border-current border-t-transparent rounded-full animate-spin shrink-0">
                  </span>
                  Scanning<span class="animate-pulse">…</span>
                <% else %>
                  <.icon name="hero-magnifying-glass" class="w-3.5 h-3.5" /> Scan tech stack
                <% end %>
              </button>
            <% end %>
          </div>

          <%!-- Individual Scans --%>
          <div class="pt-4 border-t border-neutral-100 dark:border-neutral-800 space-y-1">
            <span class="text-[10px] font-medium tracking-wider uppercase text-neutral-400 block mb-2">
              Individual probes
            </span>

            <button
              type="button"
              phx-click="scan_dnsx"
              phx-target={@myself}
              disabled={@scan_disabled?}
              title={scan_disabled_title(@can_scan?, @scannable?, @domain.lifecycle_state)}
              class="w-full flex items-center justify-between px-3 py-2 text-xs font-light text-neutral-600 hover:text-neutral-900 hover:bg-neutral-50 dark:hover:bg-neutral-800 rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <span class="flex items-center gap-2">
                <.icon name="hero-server" class="w-3.5 h-3.5 text-neutral-400" /> DNS records
              </span>
              <%= if @scanning && @active_scan_kind == :dnsx do %>
                <span class="w-3 h-3 border border-current border-t-transparent rounded-full animate-spin">
                </span>
              <% else %>
                <span class="text-[10px] text-neutral-400 font-mono">dnsx</span>
              <% end %>
            </button>

            <button
              type="button"
              phx-click="scan_httpx"
              phx-target={@myself}
              disabled={@scan_disabled?}
              title={scan_disabled_title(@can_scan?, @scannable?, @domain.lifecycle_state)}
              class="w-full flex items-center justify-between px-3 py-2 text-xs font-light text-neutral-600 hover:text-neutral-900 hover:bg-neutral-50 dark:hover:bg-neutral-800 rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <span class="flex items-center gap-2">
                <.icon name="hero-globe-alt" class="w-3.5 h-3.5 text-neutral-400" /> HTTP / TLS probe
              </span>
              <%= if @scanning && @active_scan_kind == :httpx do %>
                <span class="w-3 h-3 border border-current border-t-transparent rounded-full animate-spin">
                </span>
              <% else %>
                <span class="text-[10px] text-neutral-400 font-mono">httpx</span>
              <% end %>
            </button>

            <button
              type="button"
              phx-click="scan_rdap"
              phx-target={@myself}
              disabled={@scan_disabled?}
              title={scan_disabled_title(@can_scan?, @scannable?, @domain.lifecycle_state)}
              class="w-full flex items-center justify-between px-3 py-2 text-xs font-light text-neutral-600 hover:text-neutral-900 hover:bg-neutral-50 dark:hover:bg-neutral-800 rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <span class="flex items-center gap-2">
                <.icon name="hero-identification" class="w-3.5 h-3.5 text-neutral-400" /> RDAP / WHOIS
              </span>
              <%= if @scanning && @active_scan_kind == :rdap do %>
                <span class="w-3 h-3 border border-current border-t-transparent rounded-full animate-spin">
                </span>
              <% else %>
                <span class="text-[10px] text-neutral-400 font-mono">whois</span>
              <% end %>
            </button>

            <button
              type="button"
              phx-click="scan_subdomains"
              phx-target={@myself}
              disabled={@scan_disabled?}
              title={scan_disabled_title(@can_scan?, @scannable?, @domain.lifecycle_state)}
              class="w-full flex items-center justify-between px-3 py-2 text-xs font-light text-neutral-600 hover:text-neutral-900 hover:bg-neutral-50 dark:hover:bg-neutral-800 rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <span class="flex items-center gap-2">
                <.icon name="hero-rectangle-stack" class="w-3.5 h-3.5 text-neutral-400" /> Subdomains
              </span>
              <%= if @scanning && @active_scan_kind == :subdomains do %>
                <span class="w-3 h-3 border border-current border-t-transparent rounded-full animate-spin">
                </span>
              <% else %>
                <span class="text-[10px] text-neutral-400 font-mono">crt.sh</span>
              <% end %>
            </button>
          </div>
        </div>
      </div>

      {render_slot(@inner_block)}

      <.scan_quality_panels
        domain={@domain}
        a11y_scannable?={@a11y_scannable?}
        scanning={@scanning}
        a11y_running?={@a11y_running?}
        can_scan?={@can_scan?}
        a11y_scan={@a11y_scan}
        lighthouse_scan={@lighthouse_scan}
        lighthouse_running?={@lighthouse_running?}
        myself={@myself}
      />

      <.scan_schedule
        domain={@domain}
        can_manage?={@can_manage?}
        myself={@myself}
      />
    </div>
    """
  end

  defp scan_disabled_title(false, _scannable?, _state),
    do: "Insufficient permissions to scan this domain"

  defp scan_disabled_title(true, false, state) do
    label = state |> Atom.to_string() |> String.replace("_", " ")
    "Scanning is disabled for #{label} domains"
  end

  defp scan_disabled_title(true, true, _state), do: nil
end
