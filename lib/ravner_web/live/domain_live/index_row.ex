defmodule RavnerWeb.DomainLive.IndexRow do
  @moduledoc """
  Functional component rendering a single domain row (and its expandable subdomains)
  inside the `@streams.domains` list on `RavnerWeb.DomainLive.Index`.
  """
  use RavnerWeb, :html

  import RavnerWeb.DomainComponents,
    only: [
      lifecycle_dot_class: 1,
      lifecycle_dot_class: 2,
      technical_status_indicator: 1,
      row_checkbox: 1
    ]

  import RavnerWeb.DomainLive.IndexSidebar, only: [lifecycle_options: 0]

  attr :dom_id, :string, required: true
  attr :domain, :map, required: true
  attr :current_scope, :any, default: nil
  attr :selected_ids, :any, required: true
  attr :scanning_ids, :any, required: true
  attr :expanded_domains, :any, required: true
  attr :lifecycle_menu_open, :any, default: nil
  attr :a11y_violations, :map, required: true
  attr :lighthouse_scores, :map, required: true

  def domain_index_row(assigns) do
    can_scan? =
      Ravner.Accounts.ScopeResolver.can_scan_domain?(assigns.current_scope, assigns.domain)

    can_manage? =
      Ravner.Accounts.ScopeResolver.can_manage_domain?(assigns.current_scope, assigns.domain)

    scannable? = Ravner.Domains.Domain.scannable?(assigns.domain)

    assigns =
      assigns
      |> assign(:can_scan?, can_scan?)
      |> assign(:can_manage?, can_manage?)
      |> assign(:scannable?, scannable?)

    ~H"""
    <% selected = MapSet.member?(@selected_ids, "#{@domain.id}") %>
    <% scanning = MapSet.member?(@scanning_ids, "#{@domain.id}") %>
    <div
      id={@dom_id}
      class={[
        selected && "bg-neutral-50 dark:bg-neutral-800",
        scanning && "opacity-50"
      ]}
    >
      <div
        class="group flex items-center justify-between py-4 px-6 hover:bg-neutral-50 transition-colors cursor-pointer dark:hover:bg-neutral-800"
        phx-click="toggle_expand"
        phx-value-id={@domain.id}
      >
        <div class="flex items-center gap-4">
          <%!-- Always-ready checkbox (appears on hover or when items selected) --%>
          <span phx-click="toggle_select" phx-value-id={@domain.id} phx-stop>
            <.row_checkbox
              id={@domain.id}
              selected={selected}
              has_selection={MapSet.size(@selected_ids) > 0}
            />
          </span>

          <div class="relative" id={"lifecycle-menu-#{@domain.id}"}>
            <button
              phx-click={@can_manage? && "open_lifecycle_menu"}
              phx-value-id={@domain.id}
              phx-stop
              disabled={!@can_manage?}
              class={[
                "transition-transform",
                @can_manage? && "hover:scale-125 cursor-pointer",
                !@can_manage? && "cursor-not-allowed opacity-80",
                lifecycle_dot_class(@domain.lifecycle_state)
              ]}
              title={@domain.lifecycle_state |> Atom.to_string() |> String.replace("_", " ")}
            >
            </button>
            <%= if @lifecycle_menu_open == "#{@domain.id}" && @can_manage? do %>
              <div
                class="absolute left-0 top-5 z-50 bg-white border border-neutral-200 rounded-lg shadow-lg py-1 min-w-[160px]"
                phx-click-away="close_lifecycle_menu"
              >
                <%= for {state, label, _color} <- lifecycle_options() do %>
                  <button
                    phx-click="set_lifecycle"
                    phx-value-id={@domain.id}
                    phx-value-state={state}
                    class={[
                      "w-full flex items-center gap-2 px-3 py-1.5 text-xs text-left hover:bg-neutral-50 transition-colors dark:hover:bg-neutral-700",
                      @domain.lifecycle_state == state && "font-medium"
                    ]}
                  >
                    <span class={lifecycle_dot_class(state, :sm)}></span>
                    {label}
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>

          <.technical_status_indicator
            status={@domain.technical_status}
            variant={:icon}
            class="shrink-0"
          />

          <%!-- A11y compliance indicator --%>
          <%= case Map.get(@a11y_violations, @domain.id) do %>
            <% nil -> %>
              <%!-- no scan --%>
            <% 0 -> %>
              <span
                title="EAA Compliant (0 WCAG violations)"
                class="text-green-500 shrink-0"
              >
                <.icon name="hero-check-badge" class="w-4 h-4" />
              </span>
            <% count -> %>
              <span
                title={"EAA Non-Compliant (#{count} violations)"}
                class="text-red-400 shrink-0"
              >
                <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
              </span>
          <% end %>

          <%!-- Lighthouse performance indicator --%>
          <%= case Map.get(@lighthouse_scores, @domain.id) do %>
            <% nil -> %>
              <%!-- no scan --%>
            <% score when score >= 90 -> %>
              <span
                title={"Performance: #{score}"}
                class="text-green-500 shrink-0 text-[10px] font-medium"
              >
                {score}
              </span>
            <% score when score >= 50 -> %>
              <span
                title={"Performance: #{score}"}
                class="text-amber-500 shrink-0 text-[10px] font-medium"
              >
                {score}
              </span>
            <% score -> %>
              <span
                title={"Performance: #{score}"}
                class="text-red-500 shrink-0 text-[10px] font-medium"
              >
                {score}
              </span>
          <% end %>

          <%!-- Uptime heartbeat indicator --%>
          <%= if @domain.domain_metadata && @domain.domain_metadata.heartbeat_interval_minutes do %>
            <% stale =
              @domain.domain_metadata.last_heartbeat_at &&
                DateTime.diff(
                  DateTime.utc_now(),
                  @domain.domain_metadata.last_heartbeat_at,
                  :minute
                ) >
                  @domain.domain_metadata.heartbeat_interval_minutes * 3 %>
            <span
              title={"Heartbeat: every #{@domain.domain_metadata.heartbeat_interval_minutes}min — #{cond do
                stale -> "STALE (no recent checks)"
                @domain.domain_metadata.is_up -> "UP"
                true -> "DOWN"
              end}"}
              class={[
                "shrink-0 flex items-center gap-0.5",
                !stale && @domain.domain_metadata.is_up && "text-green-500",
                !stale && @domain.domain_metadata.is_up == false && "text-red-500",
                stale && "text-neutral-400"
              ]}
            >
              <.icon name="hero-heart" class="w-3.5 h-3.5" />
              <span class="text-[9px] font-medium">
                {@domain.domain_metadata.heartbeat_interval_minutes}m
              </span>
            </span>
          <% end %>

          <div class="flex items-center gap-3">
            <.link
              navigate={~p"/domains/#{@domain.id}"}
              class="text-sm font-normal hover:underline"
              phx-stop
            >
              {@domain.name}
            </.link>
            <%= if @domain.subdomains != [] do %>
              <span class="text-xs font-light text-neutral-400">
                {length(@domain.subdomains)} sub
              </span>
            <% end %>
          </div>
        </div>

        <div class="flex items-center gap-5 text-xs font-light text-neutral-500 shrink-0">
          <%!-- HTTP status / redirect --%>
          <%= if meta = @domain.domain_metadata do %>
            <%= cond do %>
              <% meta.final_url &&
                   (meta.http_status in [301, 302, 303, 307, 308] ||
                      external_redirect?(@domain.name, meta.final_url)) -> %>
                <% target = URI.parse(meta.final_url).host || meta.final_url %>
                <span class="flex items-center gap-1 text-amber-600">
                  <span class="font-normal">{meta.http_status}</span>
                  <.icon name="hero-arrow-right" class="w-3 h-3" />
                  <a
                    href={meta.final_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    phx-stop
                    class="max-w-[120px] truncate hover:underline"
                  >
                    {target}
                  </a>
                </span>
              <% meta.http_status == 200 -> %>
                <span class="flex items-center gap-1 text-green-600">
                  <span class="font-normal">200</span>
                  <.icon name="hero-arrow-right" class="w-3 h-3" />
                  <a
                    href={open_url(@domain, meta)}
                    target="_blank"
                    rel="noopener noreferrer"
                    phx-stop
                    class="max-w-[120px] truncate hover:underline"
                  >
                    {landing_label(@domain, meta)}
                  </a>
                </span>
              <% meta.http_status && meta.http_status > 0 -> %>
                <span class="text-red-500 font-normal">{meta.http_status}</span>
              <% meta.http_scanned_at != nil -> %>
                <span
                  class="text-red-400 font-normal"
                  title="Unreachable or scan failed"
                >
                  ERR
                </span>
              <% true -> %>
                <span class="text-neutral-300">–</span>
            <% end %>

            <%!-- IP --%>
            <%= if meta.ip_v4 && meta.ip_v4 != [] do %>
              <span
                class="hidden xl:inline text-neutral-400 font-mono text-[10px] tracking-tighter"
                title={Enum.join(meta.ip_v4, ", ")}
              >
                {List.first(meta.ip_v4)}
              </span>
            <% end %>

            <%!-- SSL --%>
            <%= if meta.ssl_valid_until do %>
              <% expiring_soon =
                meta.ssl_days_remaining != nil && meta.ssl_days_remaining <= 14 %>
              <% expired = meta.ssl_days_remaining != nil && meta.ssl_days_remaining < 0 %>
              <span
                class={[
                  "flex items-center gap-1.5 shrink-0",
                  expired && "text-red-600 font-medium",
                  expiring_soon && !expired && "text-amber-600 font-medium",
                  !expiring_soon && "text-neutral-400"
                ]}
                title={"SSL expires on #{Calendar.strftime(meta.ssl_valid_until, "%d-%m-%Y")}"}
              >
                <.icon
                  name={
                    if expired or expiring_soon,
                      do: "hero-shield-exclamation",
                      else: "hero-shield-check"
                  }
                  class="w-3.5 h-3.5"
                />
                <span class="text-[10px] whitespace-nowrap">
                  {Calendar.strftime(meta.ssl_valid_until, "%d-%m-%Y")}
                </span>
              </span>
            <% end %>

            <%!-- Cyber Risk Posture --%>
            <%= if meta.risk_grade do %>
              <%= if meta.risk_grade != "N/A" and is_integer(meta.risk_score) do %>
                <span
                  class={[
                    "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-mono font-semibold border shrink-0",
                    Ravner.Governance.RiskScore.badge_classes(meta.risk_grade)
                  ]}
                  title={"Cyber Risk Posture: #{meta.risk_score}/100 (#{meta.risk_grade})"}
                >
                  <.icon name="hero-shield-check" class="w-3 h-3 opacity-75" />
                  <span>{meta.risk_grade}</span>
                  <span class="text-[9px] opacity-75">{meta.risk_score}</span>
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

            <%!-- Last scanned --%>
            <%= if meta.scanned_at do %>
              <span class="hidden 2xl:inline text-neutral-300 text-[10px]">
                {Ravner.Formatting.time_ago(meta.scanned_at)}
              </span>
            <% end %>
          <% else %>
            <span class="text-neutral-300 italic text-[10px]">never scanned</span>
          <% end %>

          <%!-- Row actions (always visible, hide when row selected for cleaner look) --%>
          <div
            :if={not selected}
            class="flex items-center gap-2 opacity-0 group-hover:opacity-100 transition-opacity"
          >
            <a
              href={open_url(@domain, @domain.domain_metadata)}
              target="_blank"
              rel="noopener noreferrer"
              phx-stop
              class="text-neutral-400 hover:text-neutral-700 transition-colors"
              title="Open in new window"
            >
              <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
            </a>
            <button
              phx-click="quick_scan"
              phx-value-id={@domain.id}
              phx-stop
              disabled={scanning || !@can_scan? || !@scannable?}
              class="text-neutral-400 hover:text-neutral-700 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
              title={
                cond do
                  scanning -> "Scanning..."
                  !@can_scan? -> "Insufficient permissions"
                  !@scannable? -> "Scanning disabled for #{@domain.lifecycle_state} domains"
                  true -> "Quick scan"
                end
              }
            >
              <.icon
                name="hero-arrow-path"
                class={["w-4 h-4", scanning && "animate-spin"]}
              />
            </button>
            <button
              phx-click="delete"
              phx-value-id={@domain.id}
              data-confirm="Delete this domain?"
              disabled={!@can_manage?}
              title={if !@can_manage?, do: "Insufficient permissions", else: "Delete domain"}
              class="text-neutral-400 hover:text-red-600 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
              phx-stop
            >
              <.icon name="hero-trash" class="w-4 h-4" />
            </button>
          </div>
        </div>
      </div>

      <%!-- Subdomains --%>
      <%= if MapSet.member?(@expanded_domains, "#{@domain.id}") && @domain.subdomains != [] do %>
        <div class="bg-neutral-50 border-t border-neutral-100 divide-y divide-neutral-100 dark:bg-neutral-800/50 dark:border-neutral-700 dark:divide-neutral-700">
          <%= for sub <- @domain.subdomains do %>
            <% sub_scanning = MapSet.member?(@scanning_ids, "#{sub.id}") %>
            <div class={[
              "flex items-center justify-between py-3 px-6 pl-12 hover:bg-neutral-100 transition-colors dark:hover:bg-neutral-700",
              sub_scanning && "opacity-50"
            ]}>
              <div class="flex items-center gap-3">
                <div class="relative" id={"lifecycle-menu-#{sub.id}"}>
                  <button
                    phx-click="open_lifecycle_menu"
                    phx-value-id={sub.id}
                    phx-stop
                    class={[
                      "transition-transform hover:scale-125 cursor-pointer",
                      lifecycle_dot_class(sub.lifecycle_state, :sm)
                    ]}
                    title={sub.lifecycle_state}
                  >
                  </button>
                  <%= if @lifecycle_menu_open == "#{sub.id}" do %>
                    <div
                      class="absolute left-0 top-5 z-50 bg-white border border-neutral-200 rounded-lg shadow-lg py-1 min-w-[160px]"
                      phx-click-away="close_lifecycle_menu"
                    >
                      <%= for {state, label, _color} <- lifecycle_options() do %>
                        <button
                          phx-click="set_lifecycle"
                          phx-value-id={sub.id}
                          phx-value-state={state}
                          class={[
                            "w-full flex items-center gap-2 px-3 py-1.5 text-xs text-left hover:bg-neutral-50 transition-colors dark:hover:bg-neutral-700",
                            sub.lifecycle_state == state && "font-medium"
                          ]}
                        >
                          <span class={lifecycle_dot_class(state, :sm)}></span>
                          {label}
                        </button>
                      <% end %>
                    </div>
                  <% end %>
                </div>
                <.technical_status_indicator
                  status={sub.technical_status}
                  variant={:icon}
                  class="size-5 shrink-0"
                />
                <.link
                  navigate={~p"/domains/#{sub.id}"}
                  class="text-sm font-light hover:underline"
                >
                  {sub.name}
                </.link>
              </div>
              <div class="flex items-center gap-4 text-xs font-light text-neutral-500 shrink-0">
                <%= if sub_meta = sub.domain_metadata do %>
                  <%!-- HTTP status / redirect --%>
                  <%= cond do %>
                    <% sub_meta.final_url &&
                         (sub_meta.http_status in [301, 302, 303, 307, 308] ||
                            external_redirect?(sub.name, sub_meta.final_url)) -> %>
                      <% target =
                        URI.parse(sub_meta.final_url).host || sub_meta.final_url %>
                      <span class="flex items-center gap-1 text-amber-600">
                        <span class="font-normal">{sub_meta.http_status}</span>
                        <.icon name="hero-arrow-right" class="w-3 h-3" />
                        <a
                          href={sub_meta.final_url}
                          target="_blank"
                          rel="noopener noreferrer"
                          phx-stop
                          class="max-w-[100px] truncate hover:underline"
                        >
                          {target}
                        </a>
                      </span>
                    <% sub_meta.http_status == 200 -> %>
                      <span class="flex items-center gap-1 text-green-600">
                        <span class="font-normal">200</span>
                        <.icon name="hero-arrow-right" class="w-3 h-3" />
                        <a
                          href={open_url(sub, sub_meta)}
                          target="_blank"
                          rel="noopener noreferrer"
                          phx-stop
                          class="max-w-[100px] truncate hover:underline"
                        >
                          {landing_label(sub, sub_meta)}
                        </a>
                      </span>
                    <% sub_meta.http_status && sub_meta.http_status > 0 -> %>
                      <span class="text-red-500 font-normal">
                        {sub_meta.http_status}
                      </span>
                    <% sub_meta.http_scanned_at != nil -> %>
                      <span
                        class="text-red-400 font-normal"
                        title="Unreachable or scan failed"
                      >
                        ERR
                      </span>
                    <% true -> %>
                      <span class="text-neutral-300">–</span>
                  <% end %>

                  <%!-- IP --%>
                  <%= if sub_meta.ip_v4 && sub_meta.ip_v4 != [] do %>
                    <span
                      class="hidden xl:inline text-neutral-400 font-mono text-[10px] tracking-tighter"
                      title={Enum.join(sub_meta.ip_v4, ", ")}
                    >
                      {List.first(sub_meta.ip_v4)}
                    </span>
                  <% end %>

                  <%!-- SSL --%>
                  <%= if sub_meta.ssl_valid_until do %>
                    <% expiring_soon =
                      sub_meta.ssl_days_remaining != nil &&
                        sub_meta.ssl_days_remaining <= 14 %>
                    <% expired =
                      sub_meta.ssl_days_remaining != nil &&
                        sub_meta.ssl_days_remaining < 0 %>
                    <span
                      class={[
                        "flex items-center gap-1.5 shrink-0",
                        expired && "text-red-600 font-medium",
                        expiring_soon && !expired && "text-amber-600 font-medium",
                        !expiring_soon && "text-neutral-400"
                      ]}
                      title={"SSL expires on #{Calendar.strftime(sub_meta.ssl_valid_until, "%d-%m-%Y")}"}
                    >
                      <.icon
                        name={
                          if expired or expiring_soon,
                            do: "hero-shield-exclamation",
                            else: "hero-shield-check"
                        }
                        class="w-3 h-3"
                      />
                      <span class="text-[10px] whitespace-nowrap">
                        {Calendar.strftime(sub_meta.ssl_valid_until, "%d-%m-%Y")}
                      </span>
                    </span>
                  <% end %>

                  <%!-- Last scanned --%>
                  <%= if sub_meta.scanned_at do %>
                    <span class="hidden 2xl:inline text-neutral-300 text-[10px]">
                      {Ravner.Formatting.time_ago(sub_meta.scanned_at)}
                    </span>
                  <% end %>
                <% else %>
                  <span class="text-neutral-300 italic text-[10px]">never scanned</span>
                <% end %>

                <a
                  href={open_url(sub, sub.domain_metadata)}
                  target="_blank"
                  rel="noopener noreferrer"
                  phx-stop
                  class="text-neutral-400 hover:text-neutral-700 transition-colors"
                  title="Open in new window"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                </a>
                <% sub_scannable? = Ravner.Domains.Domain.scannable?(sub) %>
                <button
                  phx-click="quick_scan"
                  phx-value-id={sub.id}
                  phx-stop
                  disabled={sub_scanning || !@can_scan? || !sub_scannable?}
                  class="text-neutral-400 hover:text-neutral-700 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
                  title={
                    cond do
                      sub_scanning -> "Scanning..."
                      !@can_scan? -> "Insufficient permissions"
                      !sub_scannable? -> "Scanning disabled for #{sub.lifecycle_state} subdomains"
                      true -> "Quick scan"
                    end
                  }
                >
                  <.icon
                    name="hero-arrow-path"
                    class={["w-3 h-3", sub_scanning && "animate-spin"]}
                  />
                </button>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp external_redirect?(domain_name, final_url),
    do: Ravner.Scans.external_redirect?(domain_name, final_url)

  defp open_url(domain, nil), do: preferred_domain_url(domain, nil)
  defp open_url(domain, metadata), do: preferred_domain_url(domain, metadata.final_url)

  defp preferred_domain_url(_domain, url) when is_binary(url) and url != "", do: url

  defp preferred_domain_url(%{url: url}, _fallback) when is_binary(url) and url != "" do
    normalize_url(url)
  end

  defp preferred_domain_url(%{name: name}, _fallback), do: "https://#{name}"

  defp normalize_url(url) do
    if String.starts_with?(url, ["http://", "https://"]), do: url, else: "https://#{url}"
  end

  defp url_host(url) when is_binary(url) do
    case URI.parse(url) do
      %{host: host} when is_binary(host) -> String.replace_leading(host, "www.", "")
      _ -> url
    end
  end

  defp landing_label(domain, nil), do: domain.name

  defp landing_label(domain, metadata),
    do: metadata.final_url |> Kernel.||(open_url(domain, metadata)) |> url_host()
end
