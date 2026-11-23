defmodule RavnerWeb.DomainLive.LifecycleDropdown do
  @moduledoc """
  LiveComponent providing an interactive lifecycle state dropdown for a domain.
  Encapsulates menu toggle, click-away, and Ash-governed lifecycle transitions.
  """
  use RavnerWeb, :live_component

  alias Ravner.Domains

  import RavnerWeb.DomainComponents,
    only: [lifecycle_dot_class: 1, lifecycle_dot_class: 2, lifecycle_options: 0]

  defp flash_message(socket, kind, msg) do
    send(self(), {:put_flash, kind, msg})
    put_flash(socket, kind, msg)
  end

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :lifecycle_menu_open, false)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:lifecycle_menu_open, fn -> false end)

    allowed? = can_manage?(socket)
    {:ok, assign(socket, :allowed?, allowed?)}
  end

  @impl true
  def handle_event("toggle_lifecycle_menu", _, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, !socket.assigns.lifecycle_menu_open)}
  end

  @impl true
  def handle_event("close_lifecycle_menu", _, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, false)}
  end

  @impl true
  def handle_event("set_lifecycle", %{"state" => state}, socket) do
    if can_manage?(socket) do
      domain = socket.assigns.domain
      actor = socket.assigns.current_scope.user

      case Domains.set_domain_lifecycle(domain, state, actor: actor) do
        {:ok, _} ->
          updated_domain = Domains.get_domain_with_preloads!(domain.id)
          send(self(), {:domain_updated, updated_domain})

          {:noreply,
           socket
           |> assign(:domain, updated_domain)
           |> assign(:lifecycle_menu_open, false)
           |> flash_message(:info, "Lifecycle state updated to #{state}.")}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> assign(:lifecycle_menu_open, false)
           |> flash_message(:error, "Failed to update lifecycle state.")}
      end
    else
      {:noreply,
       socket
       |> assign(:lifecycle_menu_open, false)
       |> flash_message(:error, "You do not have permission to change domain lifecycle.")}
    end
  end

  defp can_manage?(socket) do
    case socket.assigns[:can_manage?] do
      nil ->
        Ravner.Accounts.ScopeResolver.can_manage_domain?(
          socket.assigns[:current_scope],
          socket.assigns[:domain]
        )

      val ->
        val
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative" id="lifecycle-menu-show">
      <button
        type="button"
        phx-click={@allowed? && "toggle_lifecycle_menu"}
        phx-target={@myself}
        disabled={!@allowed?}
        title={if !@allowed?, do: "Insufficient permissions to change lifecycle state"}
        class={[
          "inline-flex items-center gap-2 font-light transition-opacity",
          @allowed? && "hover:opacity-70 cursor-pointer",
          !@allowed? && "opacity-75 cursor-not-allowed"
        ]}
      >
        <span class={lifecycle_dot_class(@domain.lifecycle_state)}></span>
        <span class="capitalize">
          {@domain.lifecycle_state |> Atom.to_string() |> String.replace("_", " ")}
        </span>
        <.icon :if={@allowed?} name="hero-chevron-down" class="w-3 h-3 text-neutral-400" />
      </button>
      <%= if @lifecycle_menu_open && @allowed? do %>
        <div
          class="absolute left-0 top-7 z-50 bg-white border border-neutral-200 rounded-lg shadow-lg py-1 min-w-[170px] dark:bg-neutral-800 dark:border-neutral-700"
          phx-click-away="close_lifecycle_menu"
          phx-target={@myself}
        >
          <%= for {state, label, _color} <- lifecycle_options() do %>
            <button
              type="button"
              phx-click="set_lifecycle"
              phx-value-state={state}
              phx-target={@myself}
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
    """
  end
end
