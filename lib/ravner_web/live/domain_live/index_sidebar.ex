defmodule RavnerWeb.DomainLive.IndexSidebar do
  @moduledoc """
  Functional component rendering the Faceted Search & Navigation sidebar on `RavnerWeb.DomainLive.Index`.
  """
  use RavnerWeb, :html

  import RavnerWeb.DomainComponents,
    only: [
      technical_status_indicator: 1,
      technical_status_options: 0,
      facet_item: 1
    ]

  @doc """
  Returns the lifecycle filter options used in the sidebar and row menus.
  """
  @spec lifecycle_options() :: [{atom(), String.t(), String.t()}]
  def lifecycle_options do
    [
      {:priority, "Priority", "bg-teal-600"},
      {:active, "Active", "bg-green-500"},
      {:under_review, "Under review", "bg-yellow-500"},
      {:placeholder, "Placeholder", "bg-violet-500"},
      {:deprecated, "Deprecated", "bg-orange-400"},
      {:decommissioned, "Decommissioned", "bg-red-500"},
      {:abandoned, "Abandoned", "bg-neutral-400"}
    ]
  end

  attr :total, :integer, required: true
  attr :search, :string, required: true
  attr :lifecycle_filter, :list, required: true
  attr :technical_status_filter, :list, required: true
  attr :brand_filter, :list, required: true
  attr :org_filter, :list, required: true
  attr :project_filter, :list, required: true
  attr :technology_filter, :list, required: true
  attr :include_subdomains, :boolean, required: true
  attr :show_empty_facets, :boolean, required: true
  attr :monitored_only, :boolean, required: true
  attr :show_archived, :boolean, required: true
  attr :hide_placeholders, :boolean, required: true
  attr :expanded_facets, :any, required: true
  attr :facets, :map, required: true

  def domain_facets_sidebar(assigns) do
    ~H"""
    <aside class="space-y-8 sticky top-8">
      <div>
        <h1 class="text-2xl font-light tracking-tight mb-1">Domains</h1>
        <div class="space-y-2">
          <p class="text-[10px] font-normal uppercase tracking-widest text-neutral-400">
            {if @total == 0 && @search == "" && @lifecycle_filter == [] &&
                  @technical_status_filter == [] && @brand_filter == [] && @org_filter == [] &&
                  @project_filter == [],
                do: "No domains yet",
                else: "#{@total} domain#{if @total != 1, do: "s", else: ""}"}
          </p>
          <div class="flex flex-col items-start gap-1.5">
            <.toggle_badge
              active={@include_subdomains}
              phx-click="toggle_filter_subdomains"
              aria-pressed={@include_subdomains}
              title="Include subdomains in search and filters"
              id="sidebar-subdomains-toggle"
            >
              <.icon name="hero-square-2-stack" class="w-3 h-3" /> Subdomains
            </.toggle_badge>
            <.toggle_badge
              active={@show_empty_facets}
              phx-click="toggle_empty_facets"
              title="Show filters with zero results"
            >
              Show empty
            </.toggle_badge>
            <.toggle_badge
              active={@monitored_only}
              phx-click="toggle_monitored_only"
              aria-pressed={@monitored_only}
              title="Show only domains with uptime monitoring enabled"
            >
              <.icon name="hero-heart" class="w-3 h-3" /> Monitored
            </.toggle_badge>
            <.toggle_badge
              active={@show_archived}
              phx-click="toggle_show_archived"
              aria-pressed={@show_archived}
              title="Show archived domains (deprecated, decommissioned, abandoned)"
            >
              <.icon name="hero-archive-box" class="w-3 h-3" /> Archived
            </.toggle_badge>
            <.toggle_badge
              active={@hide_placeholders}
              phx-click="toggle_hide_placeholders"
              aria-pressed={@hide_placeholders}
              title="Hide placeholder domains"
            >
              <.icon name="hero-eye-slash" class="w-3 h-3" /> No placeholders
            </.toggle_badge>
          </div>
        </div>
      </div>

      <%!-- Facets --%>
      <nav class="space-y-4 pt-4">
        <%!-- Lifecycle Facet --%>
        <div>
          <.facet_header
            title="Status"
            group="lifecycle"
            expanded={MapSet.member?(@expanded_facets, "lifecycle")}
          />
          <div
            :if={MapSet.member?(@expanded_facets, "lifecycle")}
            class="space-y-1 animate-in fade-in slide-in-from-top-1 duration-200"
          >
            <%= for {state, label, color} <- lifecycle_options() do %>
              <% count =
                Enum.find_value(@facets.lifecycle, 0, fn {s, c} -> if s == state, do: c end) %>
              <% active = state in @lifecycle_filter %>
              <.facet_item
                :if={@show_empty_facets || count > 0 || active}
                type="lifecycle"
                id={state}
                active={active}
                count={count}
              >
                <span class={["w-1.5 h-1.5 rounded-full shrink-0", color]}></span>
                <span>{label}</span>
              </.facet_item>
            <% end %>
          </div>
        </div>

        <%!-- Technical Status Facet --%>
        <div>
          <.facet_header
            title="Technical"
            group="technical_status"
            expanded={MapSet.member?(@expanded_facets, "technical_status")}
          />
          <div
            :if={MapSet.member?(@expanded_facets, "technical_status")}
            class="space-y-1 animate-in fade-in slide-in-from-top-1 duration-200"
          >
            <%= for {status, label, _icon} <- technical_status_options() do %>
              <% count =
                Enum.find_value(@facets.technical_status, 0, fn {s, c} ->
                  if s == status, do: c
                end) %>
              <% active = status in @technical_status_filter %>
              <.facet_item
                :if={@show_empty_facets || count > 0 || active}
                type="technical_status"
                id={status}
                active={active}
                count={count}
              >
                <.technical_status_indicator status={status} variant={:icon} class="size-3.5" />
                <span>{label}</span>
              </.facet_item>
            <% end %>
          </div>
        </div>

        <%!-- Brands Facet --%>
        <div>
          <.facet_header
            title="Brands"
            group="brand"
            expanded={MapSet.member?(@expanded_facets, "brand")}
          />
          <div
            :if={MapSet.member?(@expanded_facets, "brand")}
            class="space-y-1 max-h-48 overflow-y-auto pr-2 scrollbar-thin animate-in fade-in slide-in-from-top-1 duration-200"
          >
            <% visible_brands =
              Enum.filter(@facets.brands, fn {id, _, count} ->
                @show_empty_facets || count > 0 || id in @brand_filter
              end) %>
            <div
              :if={visible_brands == []}
              class="px-2 py-3 text-[10px] font-light text-neutral-400 italic"
            >
              None available
            </div>
            <%= for {id, name, count} <- visible_brands do %>
              <.facet_item type="brand" id={id} active={id in @brand_filter} count={count}>
                <span class="truncate">{name}</span>
              </.facet_item>
            <% end %>
          </div>
        </div>

        <%!-- Organizations Facet --%>
        <div>
          <.facet_header
            title="Organizations"
            group="org"
            expanded={MapSet.member?(@expanded_facets, "org")}
          />
          <div
            :if={MapSet.member?(@expanded_facets, "org")}
            class="space-y-1 max-h-48 overflow-y-auto pr-2 scrollbar-thin animate-in fade-in slide-in-from-top-1 duration-200"
          >
            <% visible_orgs =
              Enum.filter(@facets.organizations, fn {id, _, count} ->
                @show_empty_facets || count > 0 || id in @org_filter
              end) %>
            <div
              :if={visible_orgs == []}
              class="px-2 py-3 text-[10px] font-light text-neutral-400 italic"
            >
              None available
            </div>
            <%= for {id, name, count} <- visible_orgs do %>
              <.facet_item type="org" id={id} active={id in @org_filter} count={count}>
                <span class="truncate">{name}</span>
              </.facet_item>
            <% end %>
          </div>
        </div>

        <%!-- Projects Facet --%>
        <div>
          <.facet_header
            title="Projects"
            group="project"
            expanded={MapSet.member?(@expanded_facets, "project")}
          />
          <div
            :if={MapSet.member?(@expanded_facets, "project")}
            class="space-y-1 max-h-64 overflow-y-auto pr-2 scrollbar-thin animate-in fade-in slide-in-from-top-1 duration-200"
          >
            <% visible_projects =
              Enum.filter(@facets.projects, fn {id, _, count} ->
                @show_empty_facets || count > 0 || id in @project_filter
              end) %>
            <div
              :if={visible_projects == []}
              class="px-2 py-3 text-[10px] font-light text-neutral-400 italic"
            >
              None available
            </div>
            <%= for {id, name, count} <- visible_projects do %>
              <.facet_item type="project" id={id} active={id in @project_filter} count={count}>
                <span class="truncate">{name}</span>
              </.facet_item>
            <% end %>
          </div>
        </div>

        <%!-- Technologies Facet (Hierarchical) --%>
        <div>
          <.facet_header
            title="Technologies"
            group="technology"
            expanded={MapSet.member?(@expanded_facets, "technology")}
          />
          <div
            :if={MapSet.member?(@expanded_facets, "technology")}
            class="space-y-0.5 max-h-80 overflow-y-auto pr-2 scrollbar-thin animate-in fade-in slide-in-from-top-1 duration-200"
          >
            <% visible_technologies =
              Enum.filter(@facets.technologies, fn {base, %{total: count}} ->
                @show_empty_facets || count > 0 || base in @technology_filter
              end) %>
            <div
              :if={visible_technologies == []}
              class="px-2 py-3 text-[10px] font-light text-neutral-400 italic"
            >
              None detected
            </div>
            <%= for {base, %{total: total, versions: versions}} <- visible_technologies do %>
              <% has_versions = versions != [] %>
              <% is_expanded = MapSet.member?(@expanded_facets, "tech:#{base}") %>
              <% base_active = base in @technology_filter %>
              <div class="group">
                <div class="flex items-center">
                  <%!-- Expand toggle for techs with versions --%>
                  <button
                    :if={has_versions}
                    type="button"
                    phx-click="toggle_facet_group"
                    phx-value-group={"tech:#{base}"}
                    class="w-4 h-4 flex items-center justify-center text-neutral-400 hover:text-neutral-600 shrink-0"
                  >
                    <.icon
                      name={if is_expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
                      class="w-3 h-3"
                    />
                  </button>
                  <span :if={!has_versions} class="w-4"></span>
                  <%!-- Main tech filter button --%>
                  <button
                    type="button"
                    phx-click="toggle_facet"
                    phx-value-type="technology"
                    phx-value-id={base}
                    class={[
                      "flex-1 flex items-center justify-between gap-2 px-2 py-1.5 text-left text-[11px] font-light transition-all cursor-pointer rounded-sm",
                      if(base_active,
                        do: "bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900",
                        else:
                          "text-neutral-600 hover:bg-neutral-100 dark:text-neutral-400 dark:hover:bg-neutral-800"
                      )
                    ]}
                  >
                    <span class="truncate font-medium">{base}</span>
                    <span class={[
                      "tabular-nums text-[10px] shrink-0",
                      if(base_active, do: "text-neutral-300", else: "text-neutral-400")
                    ]}>
                      {total}
                    </span>
                  </button>
                </div>
                <%!-- Version list (expanded) --%>
                <div
                  :if={has_versions && is_expanded}
                  class="ml-4 pl-2 border-l border-neutral-200 dark:border-neutral-700 space-y-0.5 mt-0.5"
                >
                  <%= for {ver, count, original} <- versions do %>
                    <% ver_active = original in @technology_filter %>
                    <button
                      type="button"
                      phx-click="toggle_facet"
                      phx-value-type="technology"
                      phx-value-id={original}
                      class={[
                        "w-full flex items-center justify-between gap-2 px-2 py-1 text-left text-[10px] font-light transition-all cursor-pointer rounded-sm",
                        if(ver_active,
                          do: "bg-neutral-800 text-white dark:bg-neutral-200 dark:text-neutral-900",
                          else:
                            "text-neutral-500 hover:bg-neutral-100 dark:text-neutral-500 dark:hover:bg-neutral-800"
                        )
                      ]}
                    >
                      <span class="truncate font-mono">{ver}</span>
                      <span class="tabular-nums text-[9px] text-neutral-400">{count}</span>
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </nav>
    </aside>
    """
  end
end
