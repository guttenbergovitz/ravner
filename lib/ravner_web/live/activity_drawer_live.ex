defmodule RavnerWeb.ActivityDrawerLive do
  @moduledoc """
  Global activity drawer showing real-time system status.

  Subscribes to PubSub activity messages for the current user and displays
  step-by-step scanner progress. When idle (30s without activity), rotates
  curated quotes and system mutterings every 60s.
  """
  use RavnerWeb, :live_view

  alias Ravner.ActivityLog
  alias Ravner.ActivityLog.Quotes

  @max_entries 30
  @idle_timeout 30_000
  @quote_interval 60_000

  @impl true
  def mount(_params, %{"user_id" => user_id}, socket) do
    if connected?(socket) do
      ActivityLog.subscribe(user_id)
      quote_ref = Process.send_after(self(), :quote_tick, @quote_interval)
      idle_ref = Process.send_after(self(), :idle_tick, @idle_timeout)

      {:ok,
       socket
       |> assign(:entries, [])
       |> assign(:mode, :idle)
       |> assign(:quote, format_quote(Quotes.random()))
       |> assign(:expanded, false)
       |> assign(:idle_ref, idle_ref)
       |> assign(:quote_ref, quote_ref)}
    else
      {:ok,
       socket
       |> assign(:entries, [])
       |> assign(:mode, :idle)
       |> assign(:quote, format_quote(Quotes.random()))
       |> assign(:expanded, false)
       |> assign(:idle_ref, nil)
       |> assign(:quote_ref, nil)}
    end
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:entries, [])
     |> assign(:mode, :idle)
     |> assign(:quote, "")
     |> assign(:expanded, false)
     |> assign(:idle_ref, nil)
     |> assign(:quote_ref, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="activity-drawer"
      phx-hook=".ActivityDrawer"
      class="fixed bottom-0 inset-x-0 z-50 border-t border-neutral-800 bg-neutral-900 text-neutral-300 font-mono text-xs transition-all duration-300"
      data-expanded={to_string(@expanded)}
    >
      <button
        phx-click="toggle_drawer"
        class="w-full flex items-center justify-between px-4 py-1.5 hover:bg-neutral-800/50 transition-colors cursor-pointer"
      >
        <div class="flex items-center gap-2 min-w-0 flex-1">
          <span class={[
            "w-1.5 h-1.5 rounded-full shrink-0",
            @mode == :active && "bg-green-400 animate-pulse",
            @mode == :idle && "bg-neutral-600"
          ]}>
          </span>
          <span class="truncate opacity-70">
            <%= if @mode == :idle do %>
              {@quote}
            <% else %>
              <%= case List.first(@entries) do %>
                <% {_ts, _level, msg} -> %>
                  {msg}
                <% _ -> %>
                  System active…
              <% end %>
            <% end %>
          </span>
        </div>
        <.icon
          name="hero-chevron-up"
          class={[
            "w-3.5 h-3.5 shrink-0 text-neutral-500 transition-transform duration-200",
            @expanded && "rotate-180"
          ]}
        />
      </button>

      <div class={[
        "overflow-hidden transition-all duration-300",
        if(@expanded, do: "max-h-28", else: "max-h-0")
      ]}>
        <div id="activity-log" class="px-4 pb-2 space-y-0.5 overflow-y-auto max-h-24 scroll-smooth">
          <%= if @entries == [] do %>
            <p class="text-neutral-600 italic py-2">No recent activity</p>
          <% else %>
            <%= for {ts, level, msg} <- Enum.reverse(@entries) do %>
              <div class="flex items-start gap-2">
                <span class="text-neutral-600 shrink-0">{ts}</span>
                <span class={[
                  level == :done && "text-green-400",
                  level == :error && "text-amber-400",
                  level == :step && "text-neutral-400"
                ]}>
                  {msg}
                </span>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ActivityDrawer">
      export default {
        mounted() {
          const saved = localStorage.getItem("activity_drawer_expanded")
          if (saved === "true") {
            this.pushEvent("set_expanded", {expanded: true})
          }
        },
        updated() {
          const expanded = this.el.dataset.expanded === "true"
          localStorage.setItem("activity_drawer_expanded", expanded)
          if (expanded) {
            const log = document.getElementById("activity-log")
            if (log) log.scrollTop = log.scrollHeight
          }
        }
      }
    </script>
    """
  end

  @impl true
  def handle_event("toggle_drawer", _, socket) do
    {:noreply, assign(socket, :expanded, !socket.assigns.expanded)}
  end

  def handle_event("set_expanded", %{"expanded" => expanded}, socket) do
    {:noreply, assign(socket, :expanded, expanded)}
  end

  @impl true
  def handle_info({:activity, level, message, timestamp}, socket) do
    entry = {timestamp, level, message}
    entries = Enum.take([entry | socket.assigns.entries], @max_entries)

    # Reset idle timer
    if socket.assigns.idle_ref, do: Process.cancel_timer(socket.assigns.idle_ref)
    idle_ref = Process.send_after(self(), :idle_tick, @idle_timeout)

    {:noreply,
     socket
     |> assign(:entries, entries)
     |> assign(:mode, :active)
     |> assign(:idle_ref, idle_ref)}
  end

  def handle_info(:idle_tick, socket) do
    {:noreply,
     socket
     |> assign(:mode, :idle)
     |> assign(:quote, format_quote(Quotes.random()))}
  end

  def handle_info(:quote_tick, socket) do
    quote_ref = Process.send_after(self(), :quote_tick, @quote_interval)

    socket =
      if socket.assigns.mode == :idle do
        assign(socket, :quote, format_quote(Quotes.random()))
      else
        socket
      end

    {:noreply, assign(socket, :quote_ref, quote_ref)}
  end

  defp format_quote({text, author}), do: "\"#{text}\" — #{author}"
  defp format_quote(muttering) when is_binary(muttering), do: muttering
end
