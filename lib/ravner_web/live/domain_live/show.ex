defmodule RavnerWeb.DomainLive.Show do
  use RavnerWeb, :live_view

  alias Ravner.Domains
  alias Ravner.Scans

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :scanning, false)}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    domain = Domains.get_domain_with_preloads!(id)

    {:noreply,
     socket
     |> assign(:page_title, domain.name)
     |> assign(:domain, domain)
     |> assign(:scan_results, nil)
     |> assign(:scanning, false)}
  end

  @impl true
  def handle_event("scan_subdomains", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()
    socket = assign(socket, :scanning, true)

    Task.start(fn ->
      result = Scans.run_subdomain_scan(domain_id)
      send(liveview_pid, {:scan_done, :subdomains, result})
    end)

    {:noreply, socket}
  end

  def handle_event("scan_httpx", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()
    socket = assign(socket, :scanning, true)

    Task.start(fn ->
      result = Scans.run_httpx_scan(domain_id)
      send(liveview_pid, {:scan_done, :httpx, result})
    end)

    {:noreply, socket}
  end

  def handle_event("scan_dnsx", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()
    socket = assign(socket, :scanning, true)

    Task.start(fn ->
      result = Scans.run_dnsx_scan(domain_id)
      send(liveview_pid, {:scan_done, :dnsx, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:scan_done, :subdomains, {:ok, results}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    {:noreply,
     socket
     |> assign(:scanning, false)
     |> assign(:scan_results, results)
     |> assign(:domain, domain)
     |> put_flash(:info, "Found #{results.found} subdomains (#{results.new} new)")}
  end

  def handle_info({:scan_done, :httpx, {:ok, _}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    {:noreply,
     socket
     |> assign(:scanning, false)
     |> assign(:domain, domain)
     |> put_flash(:info, "HTTP scan completed")}
  end

  def handle_info({:scan_done, :dnsx, {:ok, _}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    {:noreply,
     socket
     |> assign(:scanning, false)
     |> assign(:domain, domain)
     |> put_flash(:info, "DNS scan completed")}
  end

  def handle_info({:scan_done, _kind, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:scanning, false)
     |> put_flash(:error, reason)}
  end

  defp lifecycle_color(:active), do: "bg-green-500"
  defp lifecycle_color(:under_review), do: "bg-yellow-500"
  defp lifecycle_color(:deprecated), do: "bg-orange-500"
  defp lifecycle_color(:decommissioned), do: "bg-red-500"
  defp lifecycle_color(:abandoned), do: "bg-neutral-400"
  defp lifecycle_color(_), do: "bg-neutral-400"
end
