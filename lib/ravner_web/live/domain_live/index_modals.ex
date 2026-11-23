defmodule RavnerWeb.DomainLive.IndexModals do
  @moduledoc """
  Functional component rendering the Bulk Action confirmation modal and Add/Import Domain modals on `RavnerWeb.DomainLive.Index`.
  """
  use RavnerWeb, :html

  attr :bulk_action, :any, default: nil
  attr :selected_ids, :any, required: true
  attr :facets, :map, required: true
  attr :bulk_include_subdomains, :boolean, default: false
  attr :live_action, :atom, default: nil
  attr :form, :any, default: nil
  attr :import_results, :any, default: nil

  def domain_index_modals(assigns) do
    ~H"""
    <%= if @bulk_action != nil do %>
      <% selected_count = MapSet.size(@selected_ids) %>
      <div class="fixed inset-0 bg-black/40 backdrop-blur-sm z-40" phx-click="bulk_action_cancel">
      </div>
      <div class="fixed inset-x-0 top-24 mx-auto max-w-md bg-white border border-neutral-200 z-50 p-8 shadow-2xl animate-in zoom-in-95 duration-200 dark:bg-neutral-800 dark:border-neutral-700">
        <h2 class="text-xl font-light tracking-tight mb-4">
          <%= case @bulk_action do %>
            <% :delete -> %>
              Delete {selected_count} domains?
            <% :scan -> %>
              Scan {selected_count} domains?
            <% :security_scan -> %>
              Run security scan on {selected_count} domains?
            <% {:lifecycle, state} -> %>
              Set {selected_count} domains to {state}?
            <% {:brand, id} -> %>
              <% {_, name, _} =
                Enum.find(@facets.brands, fn {bid, _, _} -> bid == id end) || {0, "Brand", 0} %> Assign {selected_count} domains to {name}?
            <% {:org, id} -> %>
              <% {_, name, _} =
                Enum.find(@facets.organizations, fn {oid, _, _} -> oid == id end) || {0, "Org", 0} %> Assign {selected_count} domains to {name}?
            <% {:project, id} -> %>
              <% {_, name, _} =
                Enum.find(@facets.projects, fn {pid, _, _} -> pid == id end) || {0, "Project", 0} %> Assign {selected_count} domains to {name}?
          <% end %>
        </h2>
        <p class="text-sm font-light text-neutral-500 mb-8">
          <%= case @bulk_action do %>
            <% :delete -> %>
              This action cannot be undone.
            <% :scan -> %>
              All scans will run in parallel background tasks.
            <% :security_scan -> %>
              In-process security audit (curated secret probes, TLS 1.0/1.1 & security headers, port verification) will run in parallel background tasks.
            <% _ -> %>
              This will update the selected metadata for all target domains.
          <% end %>
          <%= if @bulk_include_subdomains && @bulk_action in [:delete, :scan, :security_scan] do %>
            <br />
            <span class="text-neutral-900 font-normal dark:text-neutral-100">
              This will also include all their subdomains.
            </span>
          <% end %>
        </p>
        <div class="flex items-center gap-3">
          <button
            phx-click="bulk_action_execute"
            class={[
              "btn-line-filled flex-1 justify-center text-xs py-2.5",
              @bulk_action == :delete && "!bg-red-600 !border-red-600"
            ]}
          >
            Confirm
          </button>
          <button
            phx-click="bulk_action_cancel"
            class="btn-line flex-1 justify-center text-xs py-2.5"
          >
            Cancel
          </button>
        </div>
      </div>
    <% end %>

    <%= if @live_action in [:new, :import] do %>
      <div class="fixed inset-0 bg-black/40 backdrop-blur-sm z-40" phx-click="close_modal"></div>
      <div class="fixed inset-x-0 top-20 bottom-8 mx-auto max-w-lg bg-white border border-neutral-200 z-50 p-10 overflow-y-auto shadow-2xl animate-in zoom-in-95 duration-200 dark:bg-neutral-800 dark:border-neutral-700">
        <%= case @live_action do %>
          <% :new -> %>
            <h2 class="text-2xl font-light tracking-tight mb-8">Add Domain</h2>
            <.form
              for={@form}
              phx-change="validate"
              phx-submit="save"
              id="domain-form"
              class="space-y-6"
            >
              <.input field={@form[:type]} type="hidden" value="domain" />
              <.input
                field={@form[:name]}
                type="text"
                label="Domain name"
                placeholder="example.com"
                required
              />
              <div class="grid grid-cols-2 gap-4 pt-4">
                <button type="submit" class="btn-line-filled justify-center py-2.5 text-xs">
                  Add domain
                </button>
                <.link patch={~p"/domains"} class="btn-line justify-center py-2.5 text-xs">
                  Cancel
                </.link>
              </div>
            </.form>
          <% :import -> %>
            <h2 class="text-2xl font-light tracking-tight mb-1">Import Domains</h2>
            <p class="text-sm font-light text-neutral-400 mb-8">Apex domains only, one per line.</p>

            <%= if @import_results do %>
              <div class="p-6 bg-neutral-50 border border-neutral-200 text-sm font-light mb-8 dark:bg-neutral-800 dark:border-neutral-700">
                Added: {length(@import_results.added)} | Skipped: {length(@import_results.skipped)} |
                Ignored: {length(@import_results.ignored)}
              </div>
              <button
                phx-click="close_modal"
                class="btn-line-filled w-full justify-center py-2.5 text-xs"
              >
                Done
              </button>
            <% else %>
              <.form
                for={%{}}
                as={:import}
                phx-submit="import"
                id="import-paste-form"
                class="space-y-6"
              >
                <textarea
                  name="import[domains]"
                  rows="10"
                  class="w-full p-4 border border-neutral-200 bg-transparent text-sm font-light font-mono resize-none focus:outline-none focus:border-neutral-900 dark:border-neutral-700 dark:focus:border-neutral-300"
                  placeholder="example.com\nexample.co.uk"
                  required
                ></textarea>
                <button type="submit" class="btn-line-filled w-full justify-center py-2.5 text-xs">
                  Import pasted
                </button>
              </.form>
              <.link patch={~p"/domains"} class="btn-line w-full justify-center py-2.5 text-xs mt-3">
                Cancel
              </.link>
            <% end %>
        <% end %>
      </div>
    <% end %>
    """
  end
end
