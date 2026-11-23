defmodule RavnerWeb.DomainComponents do
  @moduledoc """
  Provides stateless UI components for domains.
  """
  use Phoenix.Component
  use Gettext, backend: RavnerWeb.Gettext

  import RavnerWeb.CoreComponents, only: [icon: 1, status_indicator: 1]

  # ── Faceted Search Components ─────────────────────────────────────────────────

  @doc """
  Renders a single facet filter item (checkbox + label + count).
  """
  attr :type, :string, required: true
  attr :id, :any, required: true
  attr :active, :boolean, default: false
  attr :count, :integer, default: 0
  attr :disabled, :boolean, default: false
  slot :inner_block, required: true

  def facet_item(assigns) do
    ~H"""
    <button
      phx-click="toggle_facet"
      phx-value-type={@type}
      phx-value-id={@id}
      disabled={@disabled}
      class={[
        "w-full flex items-center justify-between px-2 py-1.5 text-xs transition-colors rounded group text-left",
        @active &&
          "bg-neutral-100 text-neutral-900 font-normal dark:bg-neutral-800 dark:text-neutral-100",
        !@active &&
          "text-neutral-500 hover:bg-neutral-50 font-light dark:text-neutral-400 dark:hover:bg-neutral-800",
        @count == 0 && !@active && "opacity-30"
      ]}
    >
      <div class="flex items-center gap-2 min-w-0">
        <.checkbox_indicator active={@active} />
        {render_slot(@inner_block)}
      </div>
      <span class="text-[10px] opacity-60 shrink-0 ml-2">{@count}</span>
    </button>
    """
  end

  @doc """
  Renders a simple checkbox indicator.
  """
  attr :active, :boolean, default: false
  attr :size, :atom, default: :sm, values: [:sm, :md]

  def checkbox_indicator(assigns) do
    ~H"""
    <div class={[
      "border flex items-center justify-center shrink-0 transition-colors",
      @size == :sm && "w-3 h-3",
      @size == :md && "w-4 h-4",
      @active && "bg-neutral-900 border-neutral-900 dark:bg-neutral-100 dark:border-neutral-100",
      !@active &&
        "border-neutral-300 group-hover:border-neutral-400 dark:border-neutral-600 dark:group-hover:border-neutral-500"
    ]}>
      <.icon
        :if={@active}
        name="hero-check"
        class={[
          @size == :sm && "w-2.5 h-2.5",
          @size == :md && "w-3 h-3",
          "text-white dark:text-neutral-900"
        ]}
      />
    </div>
    """
  end

  # ── Domain Row Status Components ──────────────────────────────────────────────

  @doc """
  Renders grouped health indicators for a domain row.
  Groups: a11y compliance, lighthouse score, heartbeat status.
  """
  attr :domain_id, :integer, required: true
  attr :a11y_violations, :map, default: %{}
  attr :lighthouse_scores, :map, default: %{}
  attr :domain_metadata, :any, default: nil

  def health_indicators(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 px-1.5 border-l border-neutral-100 dark:border-neutral-700">
      <%!-- A11y compliance --%>
      <%= case Map.get(@a11y_violations, @domain_id) do %>
        <% nil -> %>
        <% 0 -> %>
          <span title="EAA Compliant (0 WCAG violations)" class="text-green-500">
            <.icon name="hero-check-badge" class="w-4 h-4" />
          </span>
        <% count -> %>
          <span title={"EAA Non-Compliant (#{count} violations)"} class="text-red-400">
            <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
          </span>
      <% end %>

      <%!-- Lighthouse score --%>
      <%= case Map.get(@lighthouse_scores, @domain_id) do %>
        <% nil -> %>
        <% score when score >= 90 -> %>
          <span title={"Performance: #{score}"} class="text-green-500 text-[10px] font-medium">
            {score}
          </span>
        <% score when score >= 50 -> %>
          <span title={"Performance: #{score}"} class="text-amber-500 text-[10px] font-medium">
            {score}
          </span>
        <% score -> %>
          <span title={"Performance: #{score}"} class="text-red-500 text-[10px] font-medium">
            {score}
          </span>
      <% end %>

      <%!-- Heartbeat --%>
      <%= if @domain_metadata && @domain_metadata.heartbeat_interval_minutes do %>
        <% stale =
          @domain_metadata.last_heartbeat_at &&
            DateTime.diff(DateTime.utc_now(), @domain_metadata.last_heartbeat_at, :minute) >
              @domain_metadata.heartbeat_interval_minutes * 3 %>
        <span
          title={"Heartbeat: every #{@domain_metadata.heartbeat_interval_minutes}min — #{cond do
            stale -> "STALE"
            @domain_metadata.is_up -> "UP"
            true -> "DOWN"
          end}"}
          class={[
            "flex items-center gap-0.5",
            !stale && @domain_metadata.is_up && "text-green-500",
            !stale && @domain_metadata.is_up == false && "text-red-500",
            stale && "text-neutral-400"
          ]}
        >
          <.icon name="hero-heart" class="w-3.5 h-3.5" />
          <span class="text-[9px] font-medium">{@domain_metadata.heartbeat_interval_minutes}m</span>
        </span>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the SSL/certificate status badge.
  """
  attr :ssl_valid_until, :any, default: nil
  attr :ssl_days_remaining, :integer, default: nil

  def ssl_badge(assigns) do
    assigns =
      assigns
      |> assign(:expired, assigns.ssl_days_remaining != nil && assigns.ssl_days_remaining < 0)
      |> assign(
        :expiring_soon,
        assigns.ssl_days_remaining != nil && assigns.ssl_days_remaining <= 14 &&
          assigns.ssl_days_remaining >= 0
      )

    ~H"""
    <%= if @ssl_valid_until do %>
      <span
        class={[
          "flex items-center gap-1.5 shrink-0",
          @expired && "text-red-600 font-medium",
          @expiring_soon && "text-amber-600 font-medium",
          !@expiring_soon && !@expired && "text-neutral-400"
        ]}
        title={"SSL expires on #{Calendar.strftime(@ssl_valid_until, "%d-%m-%Y")}"}
      >
        <.icon
          name={
            if @expired or @expiring_soon, do: "hero-shield-exclamation", else: "hero-shield-check"
          }
          class="w-3.5 h-3.5"
        />
        <span class="text-[10px] whitespace-nowrap">
          {Calendar.strftime(@ssl_valid_until, "%d-%m-%Y")}
        </span>
      </span>
    <% end %>
    """
  end

  @doc """
  Renders the cyber risk posture badge.
  """
  attr :risk_grade, :string, default: nil
  attr :risk_score, :integer, default: nil

  def risk_badge(assigns) do
    ~H"""
    <%= if @risk_grade do %>
      <%= if @risk_grade != "N/A" and is_integer(@risk_score) do %>
        <span
          class={[
            "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-mono font-semibold border shrink-0",
            Ravner.Governance.RiskScore.badge_classes(@risk_grade)
          ]}
          title={"Cyber Risk Posture: #{@risk_score}/100 (#{@risk_grade})"}
        >
          <.icon name="hero-shield-check" class="w-3 h-3 opacity-75" />
          <span>{@risk_grade}</span>
          <span class="text-[9px] opacity-75">{@risk_score}</span>
        </span>
      <% else %>
        <span
          class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-mono font-semibold border shrink-0 bg-neutral-100 text-neutral-500 border-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:border-neutral-700"
          title="Cyber Risk Posture: Pending initial scans"
        >
          <.icon name="hero-shield-exclamation" class="w-3 h-3 opacity-50" />
          <span>N/A</span>
        </span>
      <% end %>
    <% end %>
    """
  end

  # ── Selection Components ──────────────────────────────────────────────────────

  @doc """
  Renders a floating selection action bar that appears when items are selected.
  """
  attr :selected_count, :integer, required: true
  attr :total, :integer, required: true
  attr :visible_count, :integer, required: true
  attr :actions_open, :boolean, default: false
  slot :actions, required: true

  def selection_bar(assigns) do
    ~H"""
    <div
      :if={@selected_count > 0}
      class="sticky top-0 z-40 flex items-center justify-between p-3 bg-white/95 backdrop-blur border-b border-neutral-200 -mx-6 px-6 animate-in slide-in-from-top-2 duration-200 dark:bg-neutral-900/95 dark:border-neutral-700"
    >
      <div class="flex items-center gap-4">
        <div class="flex items-center gap-1 text-sm">
          <span class="font-medium">{@selected_count}</span>
          <span class="text-neutral-400">selected</span>
        </div>

        <div class="flex items-center gap-2 border-l border-neutral-200 pl-4 dark:border-neutral-700">
          <button
            phx-click="select_all_matching"
            class="text-xs text-neutral-500 hover:text-neutral-900 transition-colors dark:hover:text-neutral-100"
          >
            All {@total}
          </button>
          <span class="text-neutral-300">·</span>
          <button
            phx-click="select_visible"
            class="text-xs text-neutral-500 hover:text-neutral-900 transition-colors dark:hover:text-neutral-100"
          >
            Visible {@visible_count}
          </button>
          <span class="text-neutral-300">·</span>
          <button
            phx-click="clear_selection"
            class="text-xs text-red-500 hover:text-red-700 transition-colors"
          >
            Clear
          </button>
        </div>
      </div>

      <div class="flex items-center gap-3">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a row checkbox that appears on hover or when in selection state.
  """
  attr :selected, :boolean, default: false
  attr :has_selection, :boolean, default: false
  attr :id, :any, required: true

  def row_checkbox(assigns) do
    ~H"""
    <span
      phx-click="toggle_select"
      phx-value-id={@id}
      class={[
        "w-4 h-4 border flex items-center justify-center shrink-0 transition-all cursor-pointer",
        @selected && "border-neutral-900 bg-neutral-900 dark:border-neutral-100 dark:bg-neutral-100",
        !@selected &&
          "border-neutral-300 hover:border-neutral-600 dark:border-neutral-600 dark:hover:border-neutral-400",
        !@has_selection && !@selected && "opacity-0 group-hover:opacity-100"
      ]}
    >
      <.icon :if={@selected} name="hero-check" class="w-3 h-3 text-white dark:text-neutral-900" />
    </span>
    """
  end

  @doc """
  Renders a scan action button with loading state.
  """
  attr :action, :string, required: true
  attr :disabled, :boolean, default: false
  attr :loading, :boolean, default: false
  attr :variant, :atom, values: [:primary, :secondary], default: :secondary
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(id)
  slot :inner_block, required: true
  slot :loading_text

  def scan_button(assigns) do
    ~H"""
    <button
      phx-click={@action}
      disabled={@disabled}
      class={[
        "w-full flex items-center justify-center gap-2 px-4 py-2.5 text-xs font-normal tracking-wide uppercase border transition-colors",
        @disabled && "opacity-50 cursor-not-allowed border-neutral-200 text-neutral-400",
        !@disabled && @variant == :primary &&
          "border-neutral-900 text-neutral-900 hover:bg-neutral-900 hover:text-white",
        !@disabled && @variant == :secondary &&
          "border-neutral-300 text-neutral-600 hover:border-neutral-900 hover:text-neutral-900",
        @class
      ]}
      {@rest}
    >
      <%= if @loading do %>
        <span class="w-3.5 h-3.5 border border-current border-t-transparent rounded-full animate-spin shrink-0">
        </span>
        {render_slot(@loading_text)}
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </button>
    """
  end

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
        <.status_indicator color={:green}>200 OK</.status_indicator>
      <% {:external_redirect, target} -> %>
        <.status_indicator color={:yellow}>EXT → {target}</.status_indicator>
      <% {:redirect, target} -> %>
        <.status_indicator color={:yellow}>Redirect → {target}</.status_indicator>
      <% {:client_error, code} -> %>
        <.status_indicator color={:orange}>{code} Client error</.status_indicator>
      <% {:server_error, code} -> %>
        <.status_indicator color={:red}>{code} Server error</.status_indicator>
      <% {:other, code} -> %>
        <.status_indicator color={:neutral}>HTTP {code}</.status_indicator>
      <% {:scan_error, _} -> %>
        <.status_indicator color={:red}>Scan error</.status_indicator>
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
      <span class={lifecycle_dot_class(@state)}></span>
      <span class="capitalize">
        {@state |> Atom.to_string() |> String.replace("_", " ")}
      </span>
    </div>
    """
  end

  @doc """
  Renders the scanner-observed technical status as a quiet line-art badge.
  """
  attr :status, :atom, default: :unknown
  attr :variant, :atom, default: :label, values: [:icon, :label]
  attr :class, :any, default: nil

  def technical_status_indicator(assigns) do
    assigns = assign(assigns, :status, normalize_technical_status(assigns.status))

    ~H"""
    <span
      class={[
        "inline-flex items-center justify-center text-neutral-500 transition-colors hover:text-neutral-900",
        @variant == :icon && "size-4",
        @variant == :label &&
          "gap-1.5 text-[10px] font-light uppercase tracking-[0.14em]",
        technical_status_tone(@status),
        @class
      ]}
      title={"technical: #{technical_status_label(@status)}"}
    >
      <.icon name={technical_status_icon(@status)} class="size-3.5 shrink-0" />
      <span :if={@variant == :label}>
        {technical_status_label(@status)}
      </span>
    </span>
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
  attr :current_scope, :any, default: nil

  def scan_action_panel(assigns) do
    viewer? = is_nil(assigns.current_scope) || assigns.current_scope.user.role == :viewer
    assigns = assign(assigns, :viewer?, viewer?)

    ~H"""
    <div class="card-line">
      <h2 class="text-sm font-normal tracking-wide uppercase mb-6">Discovery</h2>
      <div class="space-y-4">
        <%!-- Primary Actions --%>
        <div class="space-y-2">
          <.scan_button
            action="scan_all"
            disabled={@scanning || !is_nil(@running_security_scan) || @viewer?}
            loading={@scanning && @active_scan_kind == :all}
            variant={:primary}
          >
            <:loading_text>Scanning<span class="animate-pulse">…</span></:loading_text>
            <.icon name="hero-bolt" class="w-3.5 h-3.5" /> Run all scans
          </.scan_button>

          <%= if @domain.technical_status == :redirect do %>
            <p class="text-[10px] text-neutral-400 italic text-center py-2">
              Deep scans unavailable — domain redirects externally
            </p>
          <% else %>
            <.scan_button
              id="scan-deep-tech"
              action="scan_deep_tech"
              disabled={@scanning || !is_nil(@running_security_scan) || @viewer?}
              loading={@scanning && @active_scan_kind == :deep_tech}
            >
              <:loading_text>Scanning<span class="animate-pulse">…</span></:loading_text>
              <.icon name="hero-cpu-chip" class="w-3.5 h-3.5" /> Deep tech scan
            </.scan_button>
            <%= if @domain.domain_metadata && @domain.domain_metadata.deep_tech_scanned_at do %>
              <p class="text-[10px] text-neutral-400 text-center -mt-1">
                Last deep tech: {Calendar.strftime(
                  @domain.domain_metadata.deep_tech_scanned_at,
                  "%Y-%m-%d %H:%M"
                )}
              </p>
            <% end %>
          <% end %>

          <%= if @domain.subdomains != [] do %>
            <.scan_button
              action="scan_all_subdomains"
              disabled={@scanning || !is_nil(@running_security_scan) || @viewer?}
              loading={@scanning && @active_scan_kind == :all_subdomains}
            >
              <:loading_text>Scanning subdomains<span class="animate-pulse">…</span></:loading_text>
              <.icon name="hero-bolt" class="w-3.5 h-3.5" />
              Scan {@domain.subdomains |> length()} subdomains
            </.scan_button>
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
            <.scan_button
              action="scan_subdomains"
              disabled={@scanning || !is_nil(@running_security_scan) || @viewer?}
              loading={@scanning && @active_scan_kind == :subdomains}
            >
              <:loading_text>Discovering<span class="animate-pulse">…</span></:loading_text>
              <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Discover subdomains
            </.scan_button>
            <%= if @domain.domain_metadata && @domain.domain_metadata.subdomains_scanned_at do %>
              <p class="text-[10px] text-neutral-400 text-center -mt-1">
                Last: {Calendar.strftime(
                  @domain.domain_metadata.subdomains_scanned_at,
                  "%Y-%m-%d %H:%M"
                )}
              </p>
            <% end %>

            <.scan_button
              action="scan_httpx"
              disabled={@scanning || !is_nil(@running_security_scan) || @viewer?}
              loading={@scanning && @active_scan_kind == :httpx}
            >
              <:loading_text>Scanning HTTP<span class="animate-pulse">…</span></:loading_text>
              <.icon name="hero-globe-alt" class="w-4 h-4" /> HTTP scan
            </.scan_button>
            <%= if @domain.domain_metadata && @domain.domain_metadata.http_scanned_at do %>
              <p class="text-[10px] text-neutral-400 text-center -mt-1">
                Last: {Calendar.strftime(@domain.domain_metadata.http_scanned_at, "%Y-%m-%d %H:%M")}
              </p>
            <% end %>

            <.scan_button
              action="scan_dnsx"
              disabled={@scanning || !is_nil(@running_security_scan) || @viewer?}
              loading={@scanning && @active_scan_kind == :dnsx}
            >
              <:loading_text>Scanning DNS<span class="animate-pulse">…</span></:loading_text>
              <.icon name="hero-server-stack" class="w-4 h-4" /> DNS scan
            </.scan_button>
            <%= if @domain.domain_metadata && @domain.domain_metadata.dns_scanned_at do %>
              <p class="text-[10px] text-neutral-400 text-center -mt-1">
                Last: {Calendar.strftime(@domain.domain_metadata.dns_scanned_at, "%Y-%m-%d %H:%M")}
              </p>
            <% end %>

            <.scan_button
              action="scan_rdap"
              disabled={@scanning || !is_nil(@running_security_scan) || @viewer?}
              loading={@scanning && @active_scan_kind == :rdap}
            >
              <:loading_text>Scanning RDAP<span class="animate-pulse">…</span></:loading_text>
              <.icon name="hero-identification" class="w-4 h-4" /> Registration scan
            </.scan_button>
            <%= if @domain.domain_metadata && @domain.domain_metadata.rdap_scanned_at do %>
              <p class="text-[10px] text-neutral-400 text-center -mt-1">
                Last: {Calendar.strftime(@domain.domain_metadata.rdap_scanned_at, "%Y-%m-%d %H:%M")}
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
  def lifecycle_color(:redirect_internal), do: "bg-sky-500"
  def lifecycle_color(:redirect_external), do: "bg-indigo-500"
  def lifecycle_color(:deprecated), do: "bg-orange-500"
  def lifecycle_color(:decommissioned), do: "bg-red-500"
  def lifecycle_color(:abandoned), do: "bg-neutral-400"
  def lifecycle_color(_), do: "bg-neutral-400"

  @doc """
  Returns the icon name for scanner-observed technical status.
  """
  def technical_status_icon(:reachable), do: "hero-shield-check"
  def technical_status_icon(:redirect), do: "hero-arrow-top-right-on-square"
  def technical_status_icon(:insecure), do: "hero-exclamation-triangle"
  def technical_status_icon(:error), do: "hero-x-circle"
  def technical_status_icon(_), do: "hero-question-mark-circle"

  @doc """
  Returns the label for scanner-observed technical status.
  """
  def technical_status_label(status) do
    status
    |> normalize_technical_status()
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  @doc """
  Returns the visual classes for a lifecycle marker.
  """
  def lifecycle_dot_class(state, size \\ :md)

  def lifecycle_dot_class(state, :sm) do
    [
      "size-2 rounded-full shrink-0 ring-1 ring-white/80 ring-offset-1 ring-offset-white",
      lifecycle_color(state)
    ]
  end

  def lifecycle_dot_class(state, :md) do
    [
      "size-2.5 rounded-full shrink-0 ring-1 ring-white/80 ring-offset-1 ring-offset-white shadow-[0_1px_1px_rgba(0,0,0,0.05)]",
      lifecycle_color(state)
    ]
  end

  @doc """
  Returns subtle text/border tone classes for scanner-observed technical status.
  """
  def technical_status_tone(:reachable), do: "text-emerald-700"
  def technical_status_tone(:redirect), do: "text-sky-700"
  def technical_status_tone(:insecure), do: "text-amber-700"
  def technical_status_tone(:error), do: "text-red-700"
  def technical_status_tone(_), do: "text-neutral-400"

  @doc """
  Returns all scanner-observed technical status options.
  """
  def technical_status_options do
    [
      {:unknown, "Unknown", "hero-question-mark-circle"},
      {:reachable, "Reachable", "hero-shield-check"},
      {:redirect, "Redirect", "hero-arrow-top-right-on-square"},
      {:insecure, "Insecure", "hero-exclamation-triangle"},
      {:error, "Error", "hero-x-circle"}
    ]
  end

  @doc """
  Returns all lifecycle options.
  """
  def lifecycle_options do
    [
      {:priority, "Priority", "bg-teal-600"},
      {:active, "Active", "bg-green-500"},
      {:under_review, "Under review", "bg-yellow-500"},
      {:placeholder, "Placeholder", "bg-violet-500"},
      {:redirect_internal, "Redirect (Internal)", "bg-sky-500"},
      {:redirect_external, "Redirect (External)", "bg-indigo-500"},
      {:deprecated, "Deprecated", "bg-orange-500"},
      {:decommissioned, "Decommissioned", "bg-red-500"},
      {:abandoned, "Abandoned", "bg-neutral-400"}
    ]
  end

  defp normalize_technical_status(nil), do: :unknown
  defp normalize_technical_status(status) when is_atom(status), do: status

  defp normalize_technical_status(status) when is_binary(status),
    do: String.to_existing_atom(status)

  defp badge_data(counts) do
    [
      {"critical", counts.critical, "bg-red-50 text-red-600"},
      {"high", counts.high, "bg-orange-50 text-orange-600"},
      {"medium", counts.medium, "bg-yellow-50 text-yellow-700"},
      {"low", counts.low, "bg-blue-50 text-blue-600"}
    ]
  end

  @doc """
  Renders the governance audit trail / timeline of state transitions and ownership assignments.
  """
  attr :versions, :list, default: []
  attr :brands, :list, default: []
  attr :orgs, :list, default: []
  attr :projects, :list, default: []

  def governance_audit_trail(assigns) do
    ~H"""
    <div class="card-line" id="governance-audit-trail">
      <div class="flex items-center justify-between mb-6">
        <div class="flex items-center gap-2">
          <.icon name="hero-clipboard-document-list" class="w-4 h-4 text-neutral-400" />
          <h2 class="text-sm font-normal tracking-wide uppercase">Governance Audit Trail</h2>
        </div>
        <span class="text-xs font-light text-neutral-400">
          {length(@versions)} {if length(@versions) == 1, do: "event", else: "events"}
        </span>
      </div>

      <%= if @versions == [] do %>
        <div class="text-center py-6 text-neutral-400 text-xs font-light" id="audit-trail-empty">
          <.icon
            name="hero-clock"
            class="w-6 h-6 mx-auto mb-2 text-neutral-300 dark:text-neutral-600"
          /> No governance state transitions recorded yet for this domain.
        </div>
      <% else %>
        <div class="space-y-4" id="audit-trail-timeline">
          <%= for {version, idx} <- Enum.with_index(@versions) do %>
            <div class="relative flex items-start gap-3.5 group" id={"audit-event-#{version.id}"}>
              <!-- Timeline Indicator Column (Dot + Connecting Line) -->
              <div class="flex flex-col items-center self-stretch shrink-0 w-4 pt-0.5">
                <div class={[
                  "w-4 h-4 rounded-full border-2 bg-white dark:bg-neutral-900 flex items-center justify-center shrink-0 z-10 ring-2 ring-white dark:ring-neutral-900",
                  version_dot_border(version.version_action_name)
                ]}>
                  <div class={[
                    "w-1.5 h-1.5 rounded-full shrink-0",
                    version_dot_bg(version.version_action_name)
                  ]}>
                  </div>
                </div>
                <%= if idx < length(@versions) - 1 do %>
                  <div class="w-0.5 grow bg-neutral-200 dark:bg-neutral-800 my-1"></div>
                <% end %>
              </div>
              
    <!-- Content Column -->
              <div class="flex-1 min-w-0 pb-3">
                <div class="flex items-center justify-between gap-2">
                  <div class="flex items-center gap-2 flex-wrap">
                    <span class="text-xs font-medium text-neutral-900 dark:text-neutral-100">
                      {version_title(version.version_action_name)}
                    </span>
                    <span class={[
                      "text-[10px] font-mono uppercase px-1.5 py-0.5 rounded border",
                      version_badge_class(version.version_action_name)
                    ]}>
                      {version.version_action_name}
                    </span>
                  </div>
                  <time
                    class="text-[11px] font-light text-neutral-400 shrink-0"
                    title={format_full_timestamp(version.version_inserted_at)}
                  >
                    {format_relative_timestamp(version.version_inserted_at)}
                  </time>
                </div>

                <div class="mt-1 text-xs text-neutral-600 dark:text-neutral-300">
                  {render_version_summary(version, @brands, @orgs, @projects)}
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp version_title(:set_lifecycle), do: "Lifecycle Transition"
  defp version_title(:assign_project), do: "Project Assignment"
  defp version_title(:assign_brand), do: "Brand Assignment"
  defp version_title(:assign_organization), do: "Organization Assignment"
  defp version_title(:assign_contacts), do: "Contacts Assignment"
  defp version_title(:assign_brand_manager), do: "Brand Manager Assigned"
  defp version_title(:assign_manager), do: "Organization Manager Assigned"
  defp version_title(:create), do: "Domain Registered"
  defp version_title(:update), do: "Governance Update"
  defp version_title(:destroy), do: "Domain Decommissioned"

  defp version_title(other),
    do: other |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp version_badge_class(:set_lifecycle),
    do:
      "bg-amber-50 text-amber-700 border-amber-200 dark:bg-amber-950 dark:text-amber-300 dark:border-amber-800"

  defp version_badge_class(:create),
    do:
      "bg-emerald-50 text-emerald-700 border-emerald-200 dark:bg-emerald-950 dark:text-emerald-300 dark:border-emerald-800"

  defp version_badge_class(action)
       when action in [:assign_project, :assign_brand, :assign_organization],
       do:
         "bg-indigo-50 text-indigo-700 border-indigo-200 dark:bg-indigo-950 dark:text-indigo-300 dark:border-indigo-800"

  defp version_badge_class(:assign_contacts),
    do:
      "bg-teal-50 text-teal-700 border-teal-200 dark:bg-teal-950 dark:text-teal-300 dark:border-teal-800"

  defp version_badge_class(action) when action in [:assign_brand_manager, :assign_manager],
    do:
      "bg-purple-50 text-purple-700 border-purple-200 dark:bg-purple-950 dark:text-purple-300 dark:border-purple-800"

  defp version_badge_class(:update),
    do:
      "bg-blue-50 text-blue-700 border-blue-200 dark:bg-blue-950 dark:text-blue-300 dark:border-blue-800"

  defp version_badge_class(:destroy),
    do:
      "bg-red-50 text-red-700 border-red-200 dark:bg-red-950 dark:text-red-300 dark:border-red-800"

  defp version_badge_class(_),
    do:
      "bg-neutral-50 text-neutral-600 border-neutral-200 dark:bg-neutral-800 dark:text-neutral-300 dark:border-neutral-700"

  defp version_dot_border(:set_lifecycle), do: "border-amber-500"
  defp version_dot_border(:create), do: "border-emerald-500"

  defp version_dot_border(action)
       when action in [:assign_project, :assign_brand, :assign_organization],
       do: "border-indigo-500"

  defp version_dot_border(:assign_contacts), do: "border-teal-500"

  defp version_dot_border(action) when action in [:assign_brand_manager, :assign_manager],
    do: "border-purple-500"

  defp version_dot_border(:update), do: "border-blue-500"
  defp version_dot_border(:destroy), do: "border-red-500"
  defp version_dot_border(_), do: "border-neutral-500 dark:border-neutral-400"

  defp version_dot_bg(:set_lifecycle), do: "bg-amber-500"
  defp version_dot_bg(:create), do: "bg-emerald-500"

  defp version_dot_bg(action)
       when action in [:assign_project, :assign_brand, :assign_organization], do: "bg-indigo-500"

  defp version_dot_bg(:assign_contacts), do: "bg-teal-500"

  defp version_dot_bg(action) when action in [:assign_brand_manager, :assign_manager],
    do: "bg-purple-500"

  defp version_dot_bg(:update), do: "bg-blue-500"
  defp version_dot_bg(:destroy), do: "bg-red-500"
  defp version_dot_bg(_), do: "bg-neutral-500 dark:bg-neutral-400"

  defp render_version_summary(
         %{version_action_name: :assign_brand_manager, changes: changes},
         _brands,
         _orgs,
         _projects
       ) do
    mgr_id = changes["brand_manager_id"]

    if mgr_id do
      "Assigned Brand Manager (Person ID ##{mgr_id})"
    else
      "Brand Manager cleared (unassigned)"
    end
  end

  defp render_version_summary(
         %{version_action_name: :assign_manager, changes: changes},
         _brands,
         _orgs,
         _projects
       ) do
    mgr_id = changes["manager_id"]

    if mgr_id do
      "Assigned Organization Manager (Person ID ##{mgr_id})"
    else
      "Organization Manager cleared (unassigned)"
    end
  end

  defp render_version_summary(
         %{version_action_name: :assign_contacts, changes: changes},
         _brands,
         _orgs,
         _projects
       ) do
    pm = changes["pm_email"]
    po = changes["po_email"]

    cond do
      pm && po -> "Assigned PM: #{pm}, PO: #{po}"
      pm -> "Assigned PM: #{pm}"
      po -> "Assigned PO: #{po}"
      true -> "Contacts updated"
    end
  end

  defp render_version_summary(
         %{version_action_name: :set_lifecycle, changes: %{"lifecycle_state" => state}},
         _brands,
         _orgs,
         _projects
       ) do
    state_str = state |> to_string() |> String.replace("_", " ") |> String.capitalize()
    "Transitioned lifecycle state to #{state_str}"
  end

  defp render_version_summary(
         %{version_action_name: :assign_brand, changes: changes},
         brands,
         _orgs,
         _projects
       ) do
    brand_id = changes["brand_id"]

    if brand_id do
      brand_name = find_entity_name(brands, brand_id)
      "Assigned to Brand: #{brand_name}"
    else
      "Brand ownership cleared (unassigned)"
    end
  end

  defp render_version_summary(
         %{version_action_name: :assign_organization, changes: changes},
         _brands,
         orgs,
         _projects
       ) do
    org_id = changes["organization_id"]

    if org_id do
      org_name = find_entity_name(orgs, org_id)
      "Assigned to Organization: #{org_name}"
    else
      "Organization ownership cleared (unassigned)"
    end
  end

  defp render_version_summary(
         %{version_action_name: :assign_project, changes: changes},
         _brands,
         _orgs,
         projects
       ) do
    project_id = changes["project_id"]

    if project_id do
      project_name = find_entity_name(projects, project_id)
      "Assigned to Project: #{project_name}"
    else
      "Project ownership cleared (unassigned)"
    end
  end

  defp render_version_summary(
         %{version_action_name: :create, changes: changes},
         _brands,
         _orgs,
         _projects
       ) do
    initial_state = changes["lifecycle_state"] || "active"
    "Created asset in governance registry with initial state: #{initial_state}"
  end

  defp render_version_summary(%{changes: changes}, _brands, _orgs, _projects)
       when is_map(changes) do
    keys =
      changes
      |> Map.keys()
      |> Enum.reject(&(&1 in ["updated_at", "inserted_at"]))

    if keys == [] do
      "Record updated"
    else
      "Updated: " <> Enum.join(keys, ", ")
    end
  end

  defp render_version_summary(_, _, _, _), do: "Governance update recorded"

  defp find_entity_name(list, target_id) when is_list(list) do
    target_int = if is_binary(target_id), do: String.to_integer(target_id), else: target_id

    case Enum.find(list, fn item -> item.id == target_int end) do
      nil -> "ID ##{target_id}"
      item -> Map.get(item, :display_name) || Map.get(item, :name) || "ID ##{target_id}"
    end
  rescue
    _ -> "ID ##{target_id}"
  end

  defp format_full_timestamp(nil), do: ""
  defp format_full_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp format_full_timestamp(%NaiveDateTime{} = ndt),
    do: Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S UTC")

  @doc """
  Formats a timestamp into human-readable relative string.
  """
  def format_relative_timestamp(nil), do: "recently"

  def format_relative_timestamp(dt) do
    now = DateTime.utc_now()

    dt_utc =
      case dt do
        %DateTime{} = d ->
          d

        %NaiveDateTime{} = nd ->
          DateTime.from_naive!(nd, "Etc/UTC")

        str when is_binary(str) ->
          case DateTime.from_iso8601(str) do
            {:ok, d, _} -> d
            _ -> now
          end
      end

    diff_seconds = DateTime.diff(now, dt_utc, :second)

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      diff_seconds < 2_592_000 -> "#{div(diff_seconds, 86400)}d ago"
      true -> Calendar.strftime(dt_utc, "%Y-%m-%d")
    end
  rescue
    _ -> "recently"
  end
end
