defmodule RavnerWeb.DomainComponents do
  @moduledoc """
  Provides stateless UI components for domains.
  """
  use Phoenix.Component
  use Gettext, backend: RavnerWeb.Gettext

  import RavnerWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders a row of severity badges.
  """
  attr :counts, :map, required: true

  def severity_badges(assigns) do
    ~H"""
    <div id="severity-badges" class="flex gap-1.5 items-center mt-3">
      <%= for {label, count, color} <- badge_data(@counts) do %>
        <span class={[
          "text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded-sm font-medium",
          if(count > 0, do: color, else: "bg-neutral-50 text-neutral-300")
        ]}>
          {count} {label}
        </span>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the HTTP status indicator.
  """
  attr :class, :any, required: true

  def http_status(assigns) do
    ~H"""
    <%= case @class do %>
      <% {:ok, _} -> %>
        <span class="inline-flex items-center gap-1.5 text-green-700 font-light">
          <span class="w-1.5 h-1.5 rounded-full bg-green-500 shrink-0"></span>200 OK
        </span>
      <% {:external_redirect, target} -> %>
        <span class="inline-flex items-center gap-1.5 text-yellow-700 font-light">
          <span class="w-1.5 h-1.5 rounded-full bg-yellow-500 shrink-0"></span>
          EXT → {target}
        </span>
      <% {:redirect, target} -> %>
        <span class="inline-flex items-center gap-1.5 text-yellow-600 font-light">
          <span class="w-1.5 h-1.5 rounded-full bg-yellow-400 shrink-0"></span>
          Redirect → {target}
        </span>
      <% {:client_error, code} -> %>
        <span class="inline-flex items-center gap-1.5 text-orange-700 font-light">
          <span class="w-1.5 h-1.5 rounded-full bg-orange-500 shrink-0"></span>
          {code} Client error
        </span>
      <% {:server_error, code} -> %>
        <span class="inline-flex items-center gap-1.5 text-red-700 font-light">
          <span class="w-1.5 h-1.5 rounded-full bg-red-500 shrink-0"></span>
          {code} Server error
        </span>
      <% {:other, code} -> %>
        <span class="inline-flex items-center gap-1.5 text-neutral-500 font-light">
          <span class="w-1.5 h-1.5 rounded-full bg-neutral-400 shrink-0"></span>
          HTTP {code}
        </span>
      <% {:scan_error, _} -> %>
        <span class="inline-flex items-center gap-1.5 text-red-600 font-light">
          <span class="w-1.5 h-1.5 rounded-full bg-red-500 shrink-0"></span> Scan error
        </span>
      <% {:not_scanned, _} -> %>
        <span class="text-neutral-400 font-light">not scanned</span>
    <% end %>
    """
  end

  @doc """
  Renders the lifecycle indicator dot and label.
  """
  attr :state, :atom, required: true
  attr :class, :any, default: nil

  def lifecycle_indicator(assigns) do
    ~H"""
    <div class={["inline-flex items-center gap-2 font-light", @class]}>
      <span class={[
        "w-2 h-2 rounded-full shrink-0",
        lifecycle_color(@state)
      ]}>
      </span>
      <span class="capitalize">
        {@state |> Atom.to_string() |> String.replace("_", " ")}
      </span>
    </div>
    """
  end

  @doc """
  Renders a scan action panel for domain details.
  """
  attr :domain, :any, required: true
  attr :scanning, :boolean, required: true
  attr :active_scan_kind, :atom, required: true
  attr :running_security_scan, :any, required: true
  attr :scan_results, :map, default: nil

  def scan_action_panel(assigns) do
    ~H"""
    <div class="card-line">
      <h2 class="text-sm font-normal tracking-wide uppercase mb-6">Discovery</h2>
      <div class="space-y-4">
        <%!-- Primary Actions --%>
        <div class="space-y-2">
          <button
            phx-click="scan_all"
            disabled={@scanning || !is_nil(@running_security_scan)}
            class={[
              "w-full flex items-center justify-center gap-2 px-4 py-2.5 text-xs font-normal tracking-wide uppercase border transition-colors",
              (@scanning || !is_nil(@running_security_scan)) &&
                "opacity-50 cursor-not-allowed border-neutral-200 text-neutral-400",
              !(@scanning || !is_nil(@running_security_scan)) &&
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

          <button
            id="scan-deep-tech"
            phx-click="scan_deep_tech"
            disabled={@scanning || !is_nil(@running_security_scan)}
            class={[
              "w-full flex items-center justify-center gap-2 px-4 py-2.5 text-xs font-normal tracking-wide uppercase border transition-colors",
              (@scanning || !is_nil(@running_security_scan)) &&
                "opacity-50 cursor-not-allowed border-neutral-200 text-neutral-400",
              !(@scanning || !is_nil(@running_security_scan)) &&
                "border-neutral-300 text-neutral-600 hover:border-neutral-900 hover:text-neutral-900"
            ]}
          >
            <%= if @scanning && @active_scan_kind == :deep_tech do %>
              <span class="w-3.5 h-3.5 border border-current border-t-transparent rounded-full animate-spin shrink-0">
              </span>
              Scanning<span class="animate-pulse">…</span>
            <% else %>
              <.icon name="hero-cpu-chip" class="w-3.5 h-3.5" /> Deep tech scan
            <% end %>
          </button>
          <%= if @domain.domain_metadata && @domain.domain_metadata.deep_tech_scanned_at do %>
            <p class="text-[10px] text-neutral-400 text-center -mt-1">
              Last deep tech: {Calendar.strftime(
                @domain.domain_metadata.deep_tech_scanned_at,
                "%Y-%m-%d %H:%M"
              )}
            </p>
          <% end %>

          <%= if @domain.subdomains != [] do %>
            <button
              phx-click="scan_all_subdomains"
              disabled={@scanning || !is_nil(@running_security_scan)}
              class={[
                "w-full flex items-center justify-center gap-2 px-4 py-2.5 text-xs font-normal tracking-wide uppercase border transition-colors",
                (@scanning || !is_nil(@running_security_scan)) &&
                  "opacity-50 cursor-not-allowed border-neutral-200 text-neutral-400",
                !(@scanning || !is_nil(@running_security_scan)) &&
                  "border-neutral-300 text-neutral-600 hover:border-neutral-900 hover:text-neutral-900"
              ]}
            >
              <%= if @scanning && @active_scan_kind == :all_subdomains do %>
                <span class="w-3.5 h-3.5 border border-current border-t-transparent rounded-full animate-spin shrink-0">
                </span>
                Scanning subdomains<span class="animate-pulse">…</span>
              <% else %>
                <.icon name="hero-bolt" class="w-3.5 h-3.5" />
                Scan {@domain.subdomains |> length()} subdomains
              <% end %>
            </button>
          <% end %>
        </div>

        <%!-- Individual scans --%>
        <details class="group border-t border-neutral-100 pt-3">
          <summary class="flex justify-between items-center text-xs font-medium text-neutral-500 cursor-pointer list-none hover:text-neutral-900 transition-colors">
            <span>Individual Scans</span>
            <span class="transition group-open:rotate-180">
              <.icon name="hero-chevron-down" class="w-4 h-4" />
            </span>
          </summary>

          <div class="mt-4 space-y-3">
            <button
              phx-click="scan_subdomains"
              disabled={@scanning || !is_nil(@running_security_scan)}
              class={[
                "btn-line w-full justify-center text-xs",
                (@scanning || !is_nil(@running_security_scan)) && "opacity-50 cursor-not-allowed"
              ]}
            >
              <%= if @scanning && @active_scan_kind == :subdomains do %>
                <span class="w-3 h-3 border border-current border-t-transparent rounded-full animate-spin shrink-0">
                </span>
                Discovering<span class="animate-pulse">…</span>
              <% else %>
                <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Discover subdomains
              <% end %>
            </button>
            <%= if @domain.domain_metadata && @domain.domain_metadata.subdomains_scanned_at do %>
              <p class="text-[10px] text-neutral-400 text-center -mt-1">
                Last: {Calendar.strftime(
                  @domain.domain_metadata.subdomains_scanned_at,
                  "%Y-%m-%d %H:%M"
                )}
              </p>
            <% end %>

            <button
              phx-click="scan_httpx"
              disabled={@scanning || !is_nil(@running_security_scan)}
              class={[
                "btn-line w-full justify-center text-xs",
                (@scanning || !is_nil(@running_security_scan)) && "opacity-50 cursor-not-allowed"
              ]}
            >
              <%= if @scanning && @active_scan_kind == :httpx do %>
                <span class="w-3 h-3 border border-current border-t-transparent rounded-full animate-spin shrink-0">
                </span>
                Scanning HTTP<span class="animate-pulse">…</span>
              <% else %>
                <.icon name="hero-globe-alt" class="w-4 h-4" /> HTTP scan
              <% end %>
            </button>
            <%= if @domain.domain_metadata && @domain.domain_metadata.http_scanned_at do %>
              <p class="text-[10px] text-neutral-400 text-center -mt-1">
                Last: {Calendar.strftime(
                  @domain.domain_metadata.http_scanned_at,
                  "%Y-%m-%d %H:%M"
                )}
              </p>
            <% end %>

            <button
              phx-click="scan_dnsx"
              disabled={@scanning || !is_nil(@running_security_scan)}
              class={[
                "btn-line w-full justify-center text-xs",
                (@scanning || !is_nil(@running_security_scan)) && "opacity-50 cursor-not-allowed"
              ]}
            >
              <%= if @scanning && @active_scan_kind == :dnsx do %>
                <span class="w-3 h-3 border border-current border-t-transparent rounded-full animate-spin shrink-0">
                </span>
                Scanning DNS<span class="animate-pulse">…</span>
              <% else %>
                <.icon name="hero-server-stack" class="w-4 h-4" /> DNS scan
              <% end %>
            </button>
            <%= if @domain.domain_metadata && @domain.domain_metadata.dns_scanned_at do %>
              <p class="text-[10px] text-neutral-400 text-center -mt-1">
                Last: {Calendar.strftime(
                  @domain.domain_metadata.dns_scanned_at,
                  "%Y-%m-%d %H:%M"
                )}
              </p>
            <% end %>

            <button
              phx-click="scan_rdap"
              disabled={@scanning || !is_nil(@running_security_scan)}
              class={[
                "btn-line w-full justify-center text-xs",
                (@scanning || !is_nil(@running_security_scan)) && "opacity-50 cursor-not-allowed"
              ]}
            >
              <%= if @scanning && @active_scan_kind == :rdap do %>
                <span class="w-3 h-3 border border-current border-t-transparent rounded-full animate-spin shrink-0">
                </span>
                Scanning RDAP<span class="animate-pulse">…</span>
              <% else %>
                <.icon name="hero-identification" class="w-4 h-4" /> Registration scan
              <% end %>
            </button>
            <%= if @domain.domain_metadata && @domain.domain_metadata.rdap_scanned_at do %>
              <p class="text-[10px] text-neutral-400 text-center -mt-1">
                Last: {Calendar.strftime(
                  @domain.domain_metadata.rdap_scanned_at,
                  "%Y-%m-%d %H:%M"
                )}
              </p>
            <% end %>
          </div>
        </details>
      </div>

      <%= if @scan_results do %>
        <div class="mt-4 pt-4 border-t border-neutral-100 text-sm font-light">
          <p class="text-neutral-500">
            Found: <span class="text-neutral-900">{@scan_results.found}</span>
          </p>
          <p class="text-neutral-500">
            New: <span class="text-neutral-900">{@scan_results.new}</span>
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Returns the color class for a lifecycle state.
  """
  def lifecycle_color(:priority), do: "bg-teal-600"
  def lifecycle_color(:active), do: "bg-green-500"
  def lifecycle_color(:placeholder), do: "bg-violet-500"
  def lifecycle_color(:under_review), do: "bg-yellow-500"
  def lifecycle_color(:insecure), do: "bg-amber-600"
  def lifecycle_color(:redirect), do: "bg-cyan-500"
  def lifecycle_color(:error), do: "bg-red-500"
  def lifecycle_color(:deprecated), do: "bg-orange-500"
  def lifecycle_color(:decommissioned), do: "bg-red-500"
  def lifecycle_color(:abandoned), do: "bg-neutral-400"
  def lifecycle_color(_), do: "bg-neutral-400"

  @doc """
  Returns all lifecycle options.
  """
  def lifecycle_options do
    [
      {:priority, "Priority", "bg-teal-600"},
      {:active, "Active", "bg-green-500"},
      {:under_review, "Under review", "bg-yellow-500"},
      {:placeholder, "Placeholder", "bg-violet-500"},
      {:insecure, "Insecure HTTP", "bg-amber-600"},
      {:redirect, "Redirect", "bg-cyan-500"},
      {:error, "Error", "bg-red-500"},
      {:deprecated, "Deprecated", "bg-orange-500"},
      {:decommissioned, "Decommissioned", "bg-red-500"},
      {:abandoned, "Abandoned", "bg-neutral-400"}
    ]
  end

  defp badge_data(counts) do
    [
      {"critical", counts.critical, "bg-red-50 text-red-600"},
      {"high", counts.high, "bg-orange-50 text-orange-600"},
      {"medium", counts.medium, "bg-yellow-50 text-yellow-700"},
      {"low", counts.low, "bg-blue-50 text-blue-600"}
    ]
  end
end
