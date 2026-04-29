defmodule RavnerWeb.LandingLive.Index do
  use RavnerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Ravner")}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :detail_popup, nil)}
  end

  @impl true
  def handle_event("show_detail", %{"section" => section}, socket) do
    {:noreply, assign(socket, :detail_popup, section)}
  end

  @impl true
  def handle_event("close_detail", _, socket) do
    {:noreply, assign(socket, :detail_popup, nil)}
  end
end
