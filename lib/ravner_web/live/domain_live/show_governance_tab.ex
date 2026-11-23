defmodule RavnerWeb.DomainLive.ShowGovernanceTab do
  @moduledoc """
  Functional components for the Ownership & Governance tab of `RavnerWeb.DomainLive.Show`.
  """
  use RavnerWeb, :html

  attr :domain, :map, required: true
  attr :can_manage?, :boolean, required: true
  attr :brands, :list, default: []
  attr :orgs, :list, default: []
  attr :projects, :list, default: []
  attr :primary_repo, :map, default: nil
  attr :pm_person, :map, default: nil
  attr :po_person, :map, default: nil
  attr :escalation_chain, :map, required: true

  def domain_governance_tab(assigns) do
    ~H"""
    <div class="card-line" id="governance-assignment-card">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h2 class="text-sm font-normal tracking-wide uppercase">
            Domain Ownership & Contacts
          </h2>
          <p class="text-xs text-neutral-500 font-light mt-0.5">
            <%= if @domain.lifecycle_state == :redirect_internal && @domain.redirect_target_domain do %>
              Ownership inherited from redirect target domain.
            <% else %>
              Assign the domain to an organizational hierarchy and nominate operational leads.
            <% end %>
          </p>
        </div>
        <%= if @can_manage? && @domain.lifecycle_state != :redirect_internal do %>
          <button
            type="button"
            id="open-contacts-modal-btn"
            phx-click="open_contacts_modal"
            class="btn-line text-xs py-1 px-2.5 inline-flex items-center gap-1.5"
          >
            <.icon name="hero-user-plus" class="w-3.5 h-3.5" /> Assign Contacts
          </button>
        <% else %>
          <span
            :if={!@can_manage?}
            class="text-[10px] uppercase tracking-wider px-2 py-0.5 rounded bg-neutral-100 text-neutral-500 dark:bg-neutral-800 dark:text-neutral-400"
          >
            Read-only
          </span>
        <% end %>
      </div>

      <%= if @domain.lifecycle_state == :redirect_internal && @domain.redirect_target_domain do %>
        <%!-- Inherited ownership from redirect target --%>
        <div class="mb-4 p-3 bg-sky-50 border border-sky-100 rounded-lg">
          <div class="flex items-center gap-2 text-sky-700 text-xs mb-2">
            <.icon name="hero-arrow-right-circle" class="w-4 h-4" />
            <span class="font-medium">Redirects to:</span>
            <.link
              navigate={~p"/domains/#{@domain.redirect_target_domain.id}"}
              class="hover:underline"
            >
              {@domain.redirect_target_domain.name}
            </.link>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-6 text-sm">
          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              Brand <span class="text-sky-500 text-[10px]">(inherited)</span>
            </span>
            <div class="px-2 py-1.5 bg-neutral-50 border border-neutral-100 text-sm font-light text-neutral-700 rounded">
              <%= if @domain.redirect_target_domain.brand do %>
                <.link
                  navigate={~p"/ownership/brands/#{@domain.redirect_target_domain.brand.id}"}
                  class="hover:underline"
                >
                  {@domain.redirect_target_domain.brand.display_name ||
                    @domain.redirect_target_domain.brand.name}
                </.link>
              <% else %>
                <span class="text-neutral-400 italic">—</span>
              <% end %>
            </div>
          </div>

          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              Organization <span class="text-sky-500 text-[10px]">(inherited)</span>
            </span>
            <div class="px-2 py-1.5 bg-neutral-50 border border-neutral-100 text-sm font-light text-neutral-700 rounded">
              <%= if @domain.redirect_target_domain.organization do %>
                <.link
                  navigate={
                    ~p"/ownership/organizations/#{@domain.redirect_target_domain.organization.id}"
                  }
                  class="hover:underline"
                >
                  {@domain.redirect_target_domain.organization.display_name ||
                    @domain.redirect_target_domain.organization.name}
                </.link>
              <% else %>
                <span class="text-neutral-400 italic">—</span>
              <% end %>
            </div>
          </div>

          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              Project <span class="text-sky-500 text-[10px]">(inherited)</span>
            </span>
            <div class="px-2 py-1.5 bg-neutral-50 border border-neutral-100 text-sm font-light text-neutral-700 rounded">
              <%= if @domain.redirect_target_domain.project do %>
                <.link
                  navigate={~p"/ownership/projects/#{@domain.redirect_target_domain.project.id}"}
                  class="hover:underline"
                >
                  {@domain.redirect_target_domain.project.name}
                </.link>
              <% else %>
                <span class="text-neutral-400 italic">—</span>
              <% end %>
            </div>
          </div>
        </div>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6 text-sm">
          <div>
            <div class="flex items-center justify-between mb-1">
              <span class="text-xs font-light tracking-wide uppercase text-neutral-500">
                Brand
              </span>
              <%= if @domain.brand_id do %>
                <.link
                  navigate={~p"/ownership/brands/#{@domain.brand_id}"}
                  class="text-[11px] text-neutral-500 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-200 inline-flex items-center gap-0.5"
                >
                  View Brand <.icon name="hero-arrow-up-right" class="w-3 h-3" />
                </.link>
              <% end %>
            </div>
            <form phx-change="set_brand" id="brand-select-form">
              <select
                name="brand_id"
                disabled={!@can_manage?}
                title={if !@can_manage?, do: "Insufficient permissions to change brand"}
                class={[
                  "w-full px-2 py-1.5 border border-neutral-200 bg-transparent text-sm font-light text-neutral-900 dark:text-neutral-100 dark:border-neutral-700 focus:outline-none focus:border-neutral-500 transition-colors",
                  !@can_manage? && "opacity-60 cursor-not-allowed"
                ]}
              >
                <option value="">—</option>
                <%= for b <- @brands do %>
                  <option value={b.id} selected={@domain.brand_id == b.id}>
                    {b.display_name || b.name}
                  </option>
                <% end %>
              </select>
            </form>
          </div>

          <div>
            <div class="flex items-center justify-between mb-1">
              <span class="text-xs font-light tracking-wide uppercase text-neutral-500">
                Organization
              </span>
              <%= if @domain.organization_id do %>
                <.link
                  navigate={~p"/ownership/organizations/#{@domain.organization_id}"}
                  class="text-[11px] text-neutral-500 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-200 inline-flex items-center gap-0.5"
                >
                  View Org <.icon name="hero-arrow-up-right" class="w-3 h-3" />
                </.link>
              <% end %>
            </div>
            <form phx-change="set_organization" id="org-select-form">
              <select
                name="organization_id"
                disabled={!@can_manage?}
                title={if !@can_manage?, do: "Insufficient permissions to change organization"}
                class={[
                  "w-full px-2 py-1.5 border border-neutral-200 bg-transparent text-sm font-light text-neutral-900 dark:text-neutral-100 dark:border-neutral-700 focus:outline-none focus:border-neutral-500 transition-colors",
                  !@can_manage? && "opacity-60 cursor-not-allowed"
                ]}
              >
                <option value="">—</option>
                <%= for o <- @orgs do %>
                  <%= if !@domain.brand_id || o.brand_id == @domain.brand_id do %>
                    <option value={o.id} selected={@domain.organization_id == o.id}>
                      {o.display_name || o.name}
                    </option>
                  <% end %>
                <% end %>
              </select>
            </form>
          </div>

          <% filtered_projects =
            Enum.filter(@projects, fn p ->
              !@domain.organization_id || p.organization_id == @domain.organization_id
            end) %>
          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              Project
            </span>
            <form phx-change="set_project" id="project-select-form">
              <select
                name="project_id"
                class={[
                  "w-full px-2 py-1.5 border bg-transparent text-sm font-light focus:outline-none focus:border-neutral-500 transition-colors",
                  if(filtered_projects == [] || !@can_manage?,
                    do:
                      "border-neutral-100 text-neutral-400 cursor-not-allowed dark:border-neutral-800 dark:text-neutral-600",
                    else:
                      "border-neutral-200 text-neutral-900 dark:border-neutral-700 dark:text-neutral-100"
                  )
                ]}
                disabled={filtered_projects == [] || !@can_manage?}
                title={if !@can_manage?, do: "Insufficient permissions to change project"}
              >
                <option value="">— Unassigned —</option>
                <%= for p <- filtered_projects do %>
                  <option value={p.id} selected={@domain.project_id == p.id}>
                    {p.name}
                    <%= if p.project_manager || p.product_owner do %>
                      {" (" <>
                        Enum.join(
                          Enum.reject(
                            [
                              p.project_manager &&
                                "PM: #{p.project_manager.first_name} #{p.project_manager.last_name}",
                              p.product_owner &&
                                "PO: #{p.product_owner.first_name} #{p.product_owner.last_name}"
                            ],
                            &is_nil/1
                          ),
                          " · "
                        ) <> ")"}
                    <% end %>
                  </option>
                <% end %>
              </select>
            </form>
            <%= if filtered_projects == [] do %>
              <p class="text-[10px] text-neutral-400 mt-0.5">
                No projects for selected org
              </p>
            <% end %>
            <%= if @domain.project do %>
              <div class="mt-2 p-2.5 bg-neutral-50 dark:bg-neutral-800/60 border border-neutral-100 dark:border-neutral-800 text-[11px] space-y-1.5">
                <div class="text-[10px] font-mono uppercase tracking-wider text-neutral-400 flex items-center justify-between">
                  <span class="flex items-center gap-1 text-emerald-700 dark:text-emerald-400 font-medium">
                    <.icon name="hero-shield-check" class="w-3.5 h-3.5" /> Inherited Project Roles
                  </span>
                  <.link
                    navigate={~p"/ownership/projects/#{@domain.project.id}"}
                    class="hover:underline text-primary-600 dark:text-primary-400"
                  >
                    View Project &rarr;
                  </.link>
                </div>
                <div class="grid grid-cols-2 gap-2 pt-1 border-t border-neutral-100 dark:border-neutral-700/50">
                  <div>
                    <div class="text-[10px] text-neutral-400 uppercase">
                      Project Manager
                    </div>
                    <div class="font-medium text-neutral-800 dark:text-neutral-200 truncate">
                      <%= if @domain.project.project_manager do %>
                        {@domain.project.project_manager.first_name} {@domain.project.project_manager.last_name}
                      <% else %>
                        <span class="text-neutral-400 italic">Unassigned</span>
                      <% end %>
                    </div>
                  </div>
                  <div>
                    <div class="text-[10px] text-neutral-400 uppercase">
                      Product Owner
                    </div>
                    <div class="font-medium text-neutral-800 dark:text-neutral-200 truncate">
                      <%= if @domain.project.product_owner do %>
                        {@domain.project.product_owner.first_name} {@domain.project.product_owner.last_name}
                      <% else %>
                        <span class="text-neutral-400 italic">Unassigned</span>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>

          <div>
            <span class="text-xs font-light tracking-wide uppercase text-neutral-500 block mb-1">
              Repository
            </span>
            <div class="flex items-center justify-between gap-2">
              <div>
                <%= if @primary_repo do %>
                  <a
                    href={@primary_repo.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="font-light text-neutral-900 dark:text-neutral-100 hover:underline inline-flex items-center gap-1.5"
                  >
                    <span class="text-[10px] font-mono uppercase bg-neutral-100 dark:bg-neutral-800 px-1 py-0.5 rounded text-neutral-600 dark:text-neutral-400">
                      {@primary_repo.provider || "git"}
                    </span>
                    <span>{@primary_repo.external_id || @primary_repo.url}</span>
                    <.icon
                      name="hero-arrow-top-right-on-square"
                      class="w-3.5 h-3.5 opacity-60"
                    />
                  </a>
                <% else %>
                  <%= if @domain.repository_url do %>
                    <a
                      href={@domain.repository_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="font-light hover:underline inline-flex items-center gap-1"
                    >
                      {@domain.repository_url}
                      <.icon
                        name="hero-arrow-top-right-on-square"
                        class="w-3 h-3 text-neutral-400"
                      />
                    </a>
                  <% else %>
                    <span class="text-neutral-400 font-light">—</span>
                  <% end %>
                <% end %>
              </div>
              <%= if @can_manage? do %>
                <button
                  type="button"
                  phx-click="open_link_repo"
                  class="text-xs text-neutral-500 hover:text-neutral-900 underline dark:text-neutral-400 dark:hover:text-neutral-200 shrink-0"
                >
                  {if @primary_repo || @domain.repository_url, do: "Change", else: "Link"}
                </button>
              <% end %>
            </div>
          </div>

          <div id="pm-contact-detail">
            <div class="flex items-center justify-between mb-1">
              <span class="text-xs font-light tracking-wide uppercase text-neutral-500">
                Project Manager (PM)
              </span>
              <%= if @can_manage? do %>
                <button
                  type="button"
                  id="assign-pm-btn"
                  phx-click="open_contacts_modal"
                  phx-value-focus="pm"
                  class="text-[11px] text-neutral-500 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-200 underline"
                >
                  {if @domain.pm_email, do: "Change", else: "Assign"}
                </button>
              <% end %>
            </div>
            <div class="flex items-center gap-2">
              <%= if @pm_person do %>
                <div class="flex items-center gap-1.5 min-w-0">
                  <span class="w-5 h-5 rounded-full bg-neutral-100 dark:bg-neutral-800 flex items-center justify-center text-[10px] font-medium text-neutral-700 dark:text-neutral-300 shrink-0">
                    {String.first(@pm_person.first_name || "")}{String.first(
                      @pm_person.last_name || ""
                    )}
                  </span>
                  <span class="font-light truncate text-neutral-900 dark:text-neutral-100">
                    {@pm_person.first_name} {@pm_person.last_name}
                  </span>
                </div>
                <a
                  href={"mailto:#{@domain.pm_email}"}
                  class="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-200 transition-colors shrink-0"
                  title={@domain.pm_email}
                >
                  <.icon name="hero-envelope" class="w-3.5 h-3.5" />
                </a>
              <% else %>
                <%= if @domain.pm_email do %>
                  <a
                    href={"mailto:#{@domain.pm_email}"}
                    class="font-light hover:underline text-neutral-700 dark:text-neutral-300 inline-flex items-center gap-1 truncate"
                  >
                    <.icon name="hero-envelope" class="w-3.5 h-3.5 text-neutral-400" />
                    {@domain.pm_email}
                  </a>
                <% else %>
                  <span class="text-neutral-400 font-light">—</span>
                <% end %>
              <% end %>
            </div>
          </div>

          <div id="po-contact-detail">
            <div class="flex items-center justify-between mb-1">
              <span class="text-xs font-light tracking-wide uppercase text-neutral-500">
                Product Owner (PO)
              </span>
              <%= if @can_manage? do %>
                <button
                  type="button"
                  id="assign-po-btn"
                  phx-click="open_contacts_modal"
                  phx-value-focus="po"
                  class="text-[11px] text-neutral-500 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-200 underline"
                >
                  {if @domain.po_email, do: "Change", else: "Assign"}
                </button>
              <% end %>
            </div>
            <div class="flex items-center gap-2">
              <%= if @po_person do %>
                <div class="flex items-center gap-1.5 min-w-0">
                  <span class="w-5 h-5 rounded-full bg-neutral-100 dark:bg-neutral-800 flex items-center justify-center text-[10px] font-medium text-neutral-700 dark:text-neutral-300 shrink-0">
                    {String.first(@po_person.first_name || "")}{String.first(
                      @po_person.last_name || ""
                    )}
                  </span>
                  <span class="font-light truncate text-neutral-900 dark:text-neutral-100">
                    {@po_person.first_name} {@po_person.last_name}
                  </span>
                </div>
                <a
                  href={"mailto:#{@domain.po_email}"}
                  class="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-200 transition-colors shrink-0"
                  title={@domain.po_email}
                >
                  <.icon name="hero-envelope" class="w-3.5 h-3.5" />
                </a>
              <% else %>
                <%= if @domain.po_email do %>
                  <a
                    href={"mailto:#{@domain.po_email}"}
                    class="font-light hover:underline text-neutral-700 dark:text-neutral-300 inline-flex items-center gap-1 truncate"
                  >
                    <.icon name="hero-envelope" class="w-3.5 h-3.5 text-neutral-400" />
                    {@domain.po_email}
                  </a>
                <% else %>
                  <span class="text-neutral-400 font-light">—</span>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>

    <%!-- Escalation Hierarchy Card with interactive links to manage Company & Brand Managers --%>
    <div class="card-line" id="governance-escalation-chain">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-2">
          <.icon name="hero-arrows-pointing-out" class="w-4 h-4 text-neutral-400" />
          <h2 class="text-sm font-normal tracking-wide uppercase">
            Governance Escalation Hierarchy
          </h2>
        </div>
        <span class="text-[10px] font-mono text-neutral-400 uppercase">
          3-Tier Escalation
        </span>
      </div>

      <p class="text-xs text-neutral-500 font-light mb-6">
        Structured governance and incident escalation ladder: operational asset team &rarr; company management &rarr; executive brand owner.
      </p>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <%!-- Tier 1: Project Operational --%>
        <div
          class="border border-neutral-200 dark:border-neutral-800 rounded-lg p-4 bg-neutral-50/50 dark:bg-neutral-800/30 flex flex-col justify-between"
          id="escalation-tier-1"
        >
          <div>
            <div class="flex items-center justify-between mb-2">
              <span class="text-[10px] font-mono font-medium uppercase px-1.5 py-0.5 rounded bg-blue-50 text-blue-700 border border-blue-200 dark:bg-blue-950 dark:text-blue-300 dark:border-blue-800">
                L1 · Operational
              </span>
              <span class="text-[10px] text-neutral-400">Project</span>
            </div>
            <div class="text-xs font-medium text-neutral-900 dark:text-neutral-100 mb-1 truncate">
              <%= if @escalation_chain.level_1_project.project do %>
                {@escalation_chain.level_1_project.project.name}
              <% else %>
                <span class="text-neutral-400 font-light italic">No Project</span>
              <% end %>
            </div>
            <div class="space-y-2 mt-3 text-xs">
              <div>
                <span class="text-[10px] text-neutral-400 block uppercase tracking-wider">
                  Project Manager
                </span>
                <%= if @escalation_chain.level_1_project.pm_person do %>
                  <div class="flex items-center gap-1.5 mt-0.5">
                    <span class="font-normal truncate text-neutral-800 dark:text-neutral-200">
                      {@escalation_chain.level_1_project.pm_person.first_name} {@escalation_chain.level_1_project.pm_person.last_name}
                    </span>
                    <%= if @escalation_chain.level_1_project.pm_inherited? do %>
                      <span
                        class="text-[9px] font-mono text-neutral-400 bg-neutral-100 dark:bg-neutral-800 px-1 py-0.5 rounded shrink-0"
                        title="Inherited from assigned project"
                      >
                        Project
                      </span>
                    <% end %>
                    <a
                      href={"mailto:#{@escalation_chain.level_1_project.pm_email}"}
                      class="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-200 transition-colors shrink-0"
                      title={@escalation_chain.level_1_project.pm_email}
                    >
                      <.icon name="hero-envelope" class="w-3.5 h-3.5" />
                    </a>
                  </div>
                <% else %>
                  <%= if @escalation_chain.level_1_project.pm_email do %>
                    <a
                      href={"mailto:#{@escalation_chain.level_1_project.pm_email}"}
                      class="text-neutral-700 dark:text-neutral-300 hover:underline truncate block mt-0.5"
                    >
                      {@escalation_chain.level_1_project.pm_email}
                    </a>
                  <% else %>
                    <span class="text-neutral-400 font-light italic mt-0.5 block">
                      Unassigned
                    </span>
                  <% end %>
                <% end %>
              </div>
              <div>
                <span class="text-[10px] text-neutral-400 block uppercase tracking-wider">
                  Product Owner
                </span>
                <%= if @escalation_chain.level_1_project.po_person do %>
                  <div class="flex items-center gap-1.5 mt-0.5">
                    <span class="font-normal truncate text-neutral-800 dark:text-neutral-200">
                      {@escalation_chain.level_1_project.po_person.first_name} {@escalation_chain.level_1_project.po_person.last_name}
                    </span>
                    <%= if @escalation_chain.level_1_project.po_inherited? do %>
                      <span
                        class="text-[9px] font-mono text-neutral-400 bg-neutral-100 dark:bg-neutral-800 px-1 py-0.5 rounded shrink-0"
                        title="Inherited from assigned project"
                      >
                        Project
                      </span>
                    <% end %>
                    <a
                      href={"mailto:#{@escalation_chain.level_1_project.po_email}"}
                      class="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-200 transition-colors shrink-0"
                      title={@escalation_chain.level_1_project.po_email}
                    >
                      <.icon name="hero-envelope" class="w-3.5 h-3.5" />
                    </a>
                  </div>
                <% else %>
                  <%= if @escalation_chain.level_1_project.po_email do %>
                    <a
                      href={"mailto:#{@escalation_chain.level_1_project.po_email}"}
                      class="text-neutral-700 dark:text-neutral-300 hover:underline truncate block mt-0.5"
                    >
                      {@escalation_chain.level_1_project.po_email}
                    </a>
                  <% else %>
                    <span class="text-neutral-400 font-light italic mt-0.5 block">
                      Unassigned
                    </span>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- Tier 2: Organization / Company --%>
        <div
          class="border border-neutral-200 dark:border-neutral-800 rounded-lg p-4 bg-neutral-50/50 dark:bg-neutral-800/30 flex flex-col justify-between"
          id="escalation-tier-2"
        >
          <div>
            <div class="flex items-center justify-between mb-2">
              <span class="text-[10px] font-mono font-medium uppercase px-1.5 py-0.5 rounded bg-indigo-50 text-indigo-700 border border-indigo-200 dark:bg-indigo-950 dark:text-indigo-300 dark:border-indigo-800">
                L2 · Company
              </span>
              <span class="text-[10px] text-neutral-400">Organization</span>
            </div>
            <div class="text-xs font-medium text-neutral-900 dark:text-neutral-100 mb-1 truncate">
              <%= if @escalation_chain.level_2_organization.organization do %>
                <.link
                  navigate={
                    ~p"/ownership/organizations/#{@escalation_chain.level_2_organization.organization.id}"
                  }
                  class="hover:underline"
                >
                  {@escalation_chain.level_2_organization.organization.display_name ||
                    @escalation_chain.level_2_organization.organization.name}
                </.link>
              <% else %>
                <span class="text-neutral-400 font-light italic">No Organization</span>
              <% end %>
            </div>
            <div class="mt-3 text-xs">
              <span class="text-[10px] text-neutral-400 block uppercase tracking-wider">
                Company / Org Manager
              </span>
              <%= if @escalation_chain.level_2_organization.manager do %>
                <div class="flex items-center gap-1.5 mt-0.5">
                  <.link
                    navigate={
                      ~p"/ownership/people/#{@escalation_chain.level_2_organization.manager.id}"
                    }
                    class="font-normal text-neutral-800 dark:text-neutral-200 hover:underline truncate"
                  >
                    {@escalation_chain.level_2_organization.manager.first_name} {@escalation_chain.level_2_organization.manager.last_name}
                  </.link>
                  <%= if @escalation_chain.level_2_organization.manager.email do %>
                    <a
                      href={"mailto:#{@escalation_chain.level_2_organization.manager.email}"}
                      class="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-200 transition-colors shrink-0"
                      title={@escalation_chain.level_2_organization.manager.email}
                    >
                      <.icon name="hero-envelope" class="w-3.5 h-3.5" />
                    </a>
                  <% end %>
                </div>
              <% else %>
                <span class="text-neutral-400 font-light italic mt-0.5 block">
                  Unassigned
                </span>
              <% end %>
            </div>
          </div>

          <%= if @escalation_chain.level_2_organization.organization do %>
            <div class="mt-3 pt-2 border-t border-neutral-100 dark:border-neutral-800">
              <.link
                navigate={
                  ~p"/ownership/organizations/#{@escalation_chain.level_2_organization.organization.id}"
                }
                class="text-[11px] text-neutral-500 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-200 inline-flex items-center gap-1 transition-colors"
              >
                {if @escalation_chain.level_2_organization.manager,
                  do: "Change in Company",
                  else: "Assign Company Manager"}
                <.icon name="hero-arrow-up-right" class="w-3 h-3" />
              </.link>
            </div>
          <% end %>
        </div>

        <%!-- Tier 3: Brand Executive --%>
        <div
          class="border border-neutral-200 dark:border-neutral-800 rounded-lg p-4 bg-neutral-50/50 dark:bg-neutral-800/30 flex flex-col justify-between"
          id="escalation-tier-3"
        >
          <div>
            <div class="flex items-center justify-between mb-2">
              <span class="text-[10px] font-mono font-medium uppercase px-1.5 py-0.5 rounded bg-purple-50 text-purple-700 border border-purple-200 dark:bg-purple-950 dark:text-purple-300 dark:border-purple-800">
                L3 · Brand
              </span>
              <span class="text-[10px] text-neutral-400">Executive Group</span>
            </div>
            <div class="text-xs font-medium text-neutral-900 dark:text-neutral-100 mb-1 truncate">
              <%= if @escalation_chain.level_3_brand.brand do %>
                <.link
                  navigate={~p"/ownership/brands/#{@escalation_chain.level_3_brand.brand.id}"}
                  class="hover:underline"
                >
                  {@escalation_chain.level_3_brand.brand.display_name ||
                    @escalation_chain.level_3_brand.brand.name}
                </.link>
              <% else %>
                <span class="text-neutral-400 font-light italic">No Brand</span>
              <% end %>
            </div>
            <div class="mt-3 text-xs">
              <span class="text-[10px] text-neutral-400 block uppercase tracking-wider">
                Brand Manager
              </span>
              <%= if @escalation_chain.level_3_brand.brand_manager do %>
                <div class="flex items-center gap-1.5 mt-0.5">
                  <.link
                    navigate={
                      ~p"/ownership/people/#{@escalation_chain.level_3_brand.brand_manager.id}"
                    }
                    class="font-normal text-neutral-800 dark:text-neutral-200 hover:underline truncate"
                  >
                    {@escalation_chain.level_3_brand.brand_manager.first_name} {@escalation_chain.level_3_brand.brand_manager.last_name}
                  </.link>
                  <%= if @escalation_chain.level_3_brand.brand_manager.email do %>
                    <a
                      href={"mailto:#{@escalation_chain.level_3_brand.brand_manager.email}"}
                      class="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-200 transition-colors shrink-0"
                      title={@escalation_chain.level_3_brand.brand_manager.email}
                    >
                      <.icon name="hero-envelope" class="w-3.5 h-3.5" />
                    </a>
                  <% end %>
                </div>
              <% else %>
                <span class="text-neutral-400 font-light italic mt-0.5 block">
                  Unassigned
                </span>
              <% end %>
            </div>
          </div>

          <%= if @escalation_chain.level_3_brand.brand do %>
            <div class="mt-3 pt-2 border-t border-neutral-100 dark:border-neutral-800">
              <.link
                navigate={~p"/ownership/brands/#{@escalation_chain.level_3_brand.brand.id}"}
                class="text-[11px] text-neutral-500 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-200 inline-flex items-center gap-1 transition-colors"
              >
                {if @escalation_chain.level_3_brand.brand_manager,
                  do: "Change in Brand",
                  else: "Assign Brand Manager"}
                <.icon name="hero-arrow-up-right" class="w-3 h-3" />
              </.link>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
