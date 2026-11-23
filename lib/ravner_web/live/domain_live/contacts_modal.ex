defmodule RavnerWeb.DomainLive.ContactsModal do
  @moduledoc """
  LiveComponent modal for assigning domain contacts (Project Manager & Product Owner).
  Encapsulates candidate search, candidate autocomplete filtering, and contact persistence.
  """
  use RavnerWeb, :live_component

  alias Ravner.Domains

  defp flash_message(socket, kind, msg) do
    send(self(), {:put_flash, kind, msg})
    Phoenix.LiveView.put_flash(socket, kind, msg)
  end

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    domain = assigns.domain
    candidates = Domains.contact_candidates(domain)
    pm_email = domain.pm_email || ""
    po_email = domain.po_email || ""

    socket =
      socket
      |> assign(assigns)
      |> assign(:pm_candidates, candidates.pm_candidates)
      |> assign(:po_candidates, candidates.po_candidates)
      |> assign_new(:contacts_pm_email, fn -> pm_email end)
      |> assign_new(:contacts_po_email, fn -> po_email end)
      |> assign_new(:filtered_pm_candidates, fn ->
        filter_candidates(candidates.pm_candidates, "")
      end)
      |> assign_new(:filtered_po_candidates, fn ->
        filter_candidates(candidates.po_candidates, "")
      end)

    {:ok, socket}
  end

  @impl true
  def handle_event("search_pm_contact", %{"value" => query}, socket) do
    query = String.trim(query)
    filtered = filter_candidates(socket.assigns.pm_candidates, query)

    {:noreply,
     socket
     |> assign(:contacts_pm_email, query)
     |> assign(:filtered_pm_candidates, filtered)}
  end

  @impl true
  def handle_event("search_po_contact", %{"value" => query}, socket) do
    query = String.trim(query)
    filtered = filter_candidates(socket.assigns.po_candidates, query)

    {:noreply,
     socket
     |> assign(:contacts_po_email, query)
     |> assign(:filtered_po_candidates, filtered)}
  end

  @impl true
  def handle_event("select_pm_candidate", %{"email" => email}, socket) do
    {:noreply,
     socket
     |> assign(:contacts_pm_email, email)
     |> assign(:filtered_pm_candidates, filter_candidates(socket.assigns.pm_candidates, email))}
  end

  @impl true
  def handle_event("select_po_candidate", %{"email" => email}, socket) do
    {:noreply,
     socket
     |> assign(:contacts_po_email, email)
     |> assign(:filtered_po_candidates, filter_candidates(socket.assigns.po_candidates, email))}
  end

  @impl true
  def handle_event("update_contacts_draft", %{"pm_email" => pm, "po_email" => po}, socket) do
    {:noreply,
     socket
     |> assign(:contacts_pm_email, pm)
     |> assign(:contacts_po_email, po)}
  end

  @impl true
  def handle_event("quick_select_contact", %{"type" => "pm", "email" => email}, socket) do
    {:noreply, assign(socket, :contacts_pm_email, email)}
  end

  @impl true
  def handle_event("quick_select_contact", %{"type" => "po", "email" => email}, socket) do
    {:noreply, assign(socket, :contacts_po_email, email)}
  end

  @impl true
  def handle_event("save_contacts", %{"pm_email" => pm, "po_email" => po}, socket) do
    domain = socket.assigns.domain
    actor = socket.assigns.current_scope.user

    pm = if is_binary(pm) && String.trim(pm) != "", do: String.trim(pm), else: nil
    po = if is_binary(po) && String.trim(po) != "", do: String.trim(po), else: nil

    case Domains.assign_domain_contacts(domain, %{pm_email: pm, po_email: po}, actor: actor) do
      {:ok, _} ->
        updated_domain = Domains.get_domain_with_preloads!(domain.id)
        send(self(), {:contacts_saved, updated_domain})

        {:noreply,
         socket
         |> flash_message(:info, "Domain contacts updated successfully.")}

      {:error, :forbidden} ->
        {:noreply,
         flash_message(socket, :error, "You are not authorized to update domain contacts.")}

      {:error, _} ->
        {:noreply, flash_message(socket, :error, "Failed to update domain contacts.")}
    end
  end

  @impl true
  def handle_event("close_contacts_modal", _, socket) do
    send(self(), :close_contacts_modal)
    {:noreply, socket}
  end

  def filter_candidates(candidates, "") do
    Enum.take(candidates, 8)
  end

  def filter_candidates(candidates, query) do
    q = String.downcase(query)

    candidates
    |> Enum.filter(fn c ->
      String.contains?(String.downcase(c.name || ""), q) or
        String.contains?(String.downcase(c.email || ""), q) or
        String.contains?(String.downcase(c.badge || ""), q)
    end)
    |> Enum.take(8)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="fixed inset-0 bg-black/50 z-50 flex items-center justify-center p-4"
      id="contacts-modal"
    >
      <div class="bg-white dark:bg-neutral-900 border border-neutral-200 dark:border-neutral-800 rounded-lg max-w-lg w-full overflow-hidden shadow-xl flex flex-col">
        <div class="flex items-center justify-between p-6 border-b border-neutral-200 dark:border-neutral-800">
          <div>
            <h2 class="text-base font-medium text-neutral-900 dark:text-neutral-100">
              Assign Domain Contacts
            </h2>
            <p class="text-xs text-neutral-500 font-light mt-0.5">
              Select project team members or enter contact emails.
            </p>
          </div>
          <button
            type="button"
            phx-click="close_contacts_modal"
            phx-target={@myself}
            class="text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100 transition-colors"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <form
          phx-change="update_contacts_draft"
          phx-submit="save_contacts"
          phx-target={@myself}
          id="contacts-form"
          class="p-6 space-y-6"
        >
          <div>
            <div class="flex items-center justify-between mb-1.5">
              <label
                for="pm-email-input"
                class="block text-xs font-light tracking-wide uppercase text-neutral-600 dark:text-neutral-400"
              >
                Project Manager (PM)
              </label>
              <span class="text-[11px] text-neutral-400 font-light">
                Autocomplete by name, email or role
              </span>
            </div>

            <div class="relative">
              <input
                type="text"
                name="pm_email"
                id="pm-email-input"
                list="pm-candidates-datalist"
                value={@contacts_pm_email}
                placeholder="Type name, email, or role to search candidates..."
                phx-keyup="search_pm_contact"
                phx-target={@myself}
                autocomplete="off"
                class="w-full px-3 py-2 border border-neutral-200 dark:border-neutral-700 rounded bg-transparent text-sm text-neutral-900 dark:text-neutral-100 focus:outline-none focus:border-neutral-500 transition-colors"
              />
              <datalist id="pm-candidates-datalist">
                <%= for candidate <- @pm_candidates do %>
                  <option value={candidate.email}>
                    {candidate.name} — {candidate.badge}
                  </option>
                <% end %>
              </datalist>
            </div>

            <%!-- Candidate suggestions with avatars and role badges --%>
            <%= if @filtered_pm_candidates != [] do %>
              <div class="mt-2.5">
                <span class="text-[11px] text-neutral-400 block mb-1.5">
                  Suggested PM candidates:
                </span>
                <div class="flex flex-wrap gap-1.5 max-h-36 overflow-y-auto p-1 border border-neutral-100 dark:border-neutral-800 rounded bg-neutral-50/50 dark:bg-neutral-800/30">
                  <%= for candidate <- @filtered_pm_candidates do %>
                    <button
                      type="button"
                      phx-click="select_pm_candidate"
                      phx-value-email={candidate.email}
                      phx-target={@myself}
                      class={[
                        "flex items-center gap-1.5 px-2 py-1 rounded text-xs border text-left transition-colors",
                        @contacts_pm_email == candidate.email &&
                          "bg-neutral-900 text-white border-neutral-900 dark:bg-white dark:text-neutral-900 dark:border-white font-medium",
                        @contacts_pm_email != candidate.email &&
                          "bg-white dark:bg-neutral-800 border-neutral-200 dark:border-neutral-700 text-neutral-800 dark:text-neutral-200 hover:border-neutral-400"
                      ]}
                      title={candidate.email}
                    >
                      <span class="w-4 h-4 rounded-full bg-neutral-200 dark:bg-neutral-700 text-[9px] flex items-center justify-center font-bold">
                        {String.first(candidate.name || candidate.email || "?")}
                      </span>
                      <span class="font-normal truncate max-w-[130px]">{candidate.name}</span>
                      <span class="text-[10px] opacity-60">({candidate.badge})</span>
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>

          <div>
            <div class="flex items-center justify-between mb-1.5">
              <label
                for="po-email-input"
                class="block text-xs font-light tracking-wide uppercase text-neutral-600 dark:text-neutral-400"
              >
                Product Owner (PO)
              </label>
              <span class="text-[11px] text-neutral-400 font-light">
                Autocomplete by name, email or role
              </span>
            </div>

            <div class="relative">
              <input
                type="text"
                name="po_email"
                id="po-email-input"
                list="po-candidates-datalist"
                value={@contacts_po_email}
                placeholder="Type name, email, or role to search candidates..."
                phx-keyup="search_po_contact"
                phx-target={@myself}
                autocomplete="off"
                class="w-full px-3 py-2 border border-neutral-200 dark:border-neutral-700 rounded bg-transparent text-sm text-neutral-900 dark:text-neutral-100 focus:outline-none focus:border-neutral-500 transition-colors"
              />
              <datalist id="po-candidates-datalist">
                <%= for candidate <- @po_candidates do %>
                  <option value={candidate.email}>
                    {candidate.name} — {candidate.badge}
                  </option>
                <% end %>
              </datalist>
            </div>

            <%!-- Candidate suggestions with avatars and role badges --%>
            <%= if @filtered_po_candidates != [] do %>
              <div class="mt-2.5">
                <span class="text-[11px] text-neutral-400 block mb-1.5">
                  Suggested PO candidates:
                </span>
                <div class="flex flex-wrap gap-1.5 max-h-36 overflow-y-auto p-1 border border-neutral-100 dark:border-neutral-800 rounded bg-neutral-50/50 dark:bg-neutral-800/30">
                  <%= for candidate <- @filtered_po_candidates do %>
                    <button
                      type="button"
                      phx-click="select_po_candidate"
                      phx-value-email={candidate.email}
                      phx-target={@myself}
                      class={[
                        "flex items-center gap-1.5 px-2 py-1 rounded text-xs border text-left transition-colors",
                        @contacts_po_email == candidate.email &&
                          "bg-neutral-900 text-white border-neutral-900 dark:bg-white dark:text-neutral-900 dark:border-white font-medium",
                        @contacts_po_email != candidate.email &&
                          "bg-white dark:bg-neutral-800 border-neutral-200 dark:border-neutral-700 text-neutral-800 dark:text-neutral-200 hover:border-neutral-400"
                      ]}
                      title={candidate.email}
                    >
                      <span class="w-4 h-4 rounded-full bg-neutral-200 dark:bg-neutral-700 text-[9px] flex items-center justify-center font-bold">
                        {String.first(candidate.name || candidate.email || "?")}
                      </span>
                      <span class="font-normal truncate max-w-[130px]">{candidate.name}</span>
                      <span class="text-[10px] opacity-60">({candidate.badge})</span>
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>

          <%= if !@domain.project_id do %>
            <p class="text-xs text-neutral-400 italic">
              Tip: Assign a Project to this domain above to enable candidate suggestions from project team roles.
            </p>
          <% end %>

          <div class="flex items-center justify-end gap-3 pt-4 border-t border-neutral-100 dark:border-neutral-800">
            <button
              type="button"
              phx-click="close_contacts_modal"
              phx-target={@myself}
              class="btn-line text-xs py-2 px-4"
            >
              Cancel
            </button>
            <button
              type="submit"
              id="save-contacts-btn"
              class="btn-line-filled text-xs py-2 px-4"
            >
              Save Contacts
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
