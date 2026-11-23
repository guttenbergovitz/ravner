defmodule RavnerWeb.AdminLive.TelemetryLive do
  @moduledoc """
  LiveView inspector for monitoring, streaming, and previewing OpenTelemetry
  and synthetic observability events in real-time.

  Connects to Phoenix PubSub topic `"telemetry:synthetic"` and renders incoming
  probe measurements, latency statistics, and OpenTelemetry Semantic Conventions metadata.
  """
  use RavnerWeb, :live_view

  alias Ravner.Telemetry.EventBuffer
  alias Ravner.Telemetry.Synthetic

  @impl true
  def mount(_params, _session, socket) do
    if can_access?(socket.assigns.current_scope) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Ravner.PubSub, "telemetry:synthetic")
      end

      initial_events = EventBuffer.list()
      stats = EventBuffer.stats()

      {:ok,
       socket
       |> assign(:page_title, "Telemetry & OTel Inspector")
       |> assign(:active_tab, :telemetry)
       |> assign(:stats, stats)
       |> assign(:filter_type, "all")
       |> assign(:paused?, false)
       |> assign(:expanded_id, nil)
       |> stream(:telemetry_events, initial_events)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have permission to access telemetry inspector.")
       |> redirect(to: ~p"/domains")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # ── PubSub Event Handling ──────────────────────────────────────────────────

  @impl true
  def handle_info({:telemetry_event, event}, socket) do
    if socket.assigns.paused? do
      {:noreply, socket}
    else
      matches_filter? =
        socket.assigns.filter_type == "all" or
          to_string(event.type) == socket.assigns.filter_type

      socket =
        if matches_filter? do
          stream_insert(socket, :telemetry_events, event, at: 0)
        else
          socket
        end

      {:noreply, assign(socket, :stats, EventBuffer.stats())}
    end
  end

  # ── User Action Events ─────────────────────────────────────────────────────

  @impl true
  def handle_event("emit_test", %{"type" => type_str}, socket) do
    type =
      case type_str do
        "sca" -> :sca
        "tls" -> :tls
        "probe" -> :probe
        "uptime" -> :uptime
        "incident" -> :incident
        "web_vitals" -> :web_vitals
        "a11y" -> :a11y
        "dns" -> :dns
        "security_headers" -> :security_headers
        _ -> :http
      end

    {:ok, _} = Synthetic.emit_test_event(type)

    {:noreply,
     put_flash(
       socket,
       :info,
       "Emitted synthetic #{String.upcase(type_str)} test event with OTel metadata."
     )}
  end

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    new_state = not socket.assigns.paused?

    msg =
      if new_state,
        do: "Live stream paused. Events are still buffered in background.",
        else: "Live stream resumed."

    {:noreply,
     socket
     |> assign(:paused?, new_state)
     |> put_flash(:info, msg)}
  end

  @impl true
  def handle_event("clear_events", _params, socket) do
    EventBuffer.clear()

    {:noreply,
     socket
     |> assign(:stats, EventBuffer.stats())
     |> stream(:telemetry_events, [], reset: true)
     |> put_flash(:info, "Telemetry buffer cleared.")}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    all_events = EventBuffer.list()

    filtered =
      if type == "all" do
        all_events
      else
        Enum.filter(all_events, &(to_string(&1.type) == type))
      end

    {:noreply,
     socket
     |> assign(:filter_type, type)
     |> stream(:telemetry_events, filtered, reset: true)}
  end

  @impl true
  def handle_event("toggle_details", %{"id" => id_str}, socket) do
    current = socket.assigns.expanded_id
    id = String.to_integer(id_str)

    new_id = if current == id, do: nil, else: id
    {:noreply, assign(socket, :expanded_id, new_id)}
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp can_access?(nil), do: false
  defp can_access?(scope), do: scope.user && scope.user.role in [:admin, :editor]
end
