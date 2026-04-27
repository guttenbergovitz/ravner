defmodule RavnerWeb.DomainLive.Show do
  use RavnerWeb, :live_view

  alias Ravner.Domains
  alias Ravner.Scans

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :scan_loading, %{})}
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

    socket = assign(socket, :scanning, true)

    case Scans.run_subdomain_scan(domain_id) do
      {:ok, results} ->
        domain = Domains.get_domain_with_preloads!(domain_id)

        {:noreply,
         socket
         |> assign(:scanning, false)
         |> assign(:scan_results, results)
         |> assign(:domain, domain)
         |> put_flash(:info, "Found #{results.found} subdomains (#{results.new} new)")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:scanning, false)
         |> put_flash(:error, reason)}
    end
  end

  def handle_event("scan_httpx", _, socket) do
    domain_id = socket.assigns.domain.id
    socket = assign(socket, :scanning, true)

    case Scans.run_httpx_scan(domain_id) do
      {:ok, _metadata} ->
        domain = Domains.get_domain_with_preloads!(domain_id)

        {:noreply,
         socket
         |> assign(:scanning, false)
         |> assign(:domain, domain)
         |> put_flash(:info, "HTTP scan completed")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:scanning, false)
         |> put_flash(:error, reason)}
    end
  end

  def handle_event("scan_dnsx", _, socket) do
    domain_id = socket.assigns.domain.id
    socket = assign(socket, :scanning, true)

    case Scans.run_dnsx_scan(domain_id) do
      {:ok, _metadata} ->
        domain = Domains.get_domain_with_preloads!(domain_id)

        {:noreply,
         socket
         |> assign(:scanning, false)
         |> assign(:domain, domain)
         |> put_flash(:info, "DNS scan completed")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:scanning, false)
         |> put_flash(:error, reason)}
    end
  end

  defp lifecycle_color(:active), do: "bg-green-500"
  defp lifecycle_color(:under_review), do: "bg-yellow-500"
  defp lifecycle_color(:deprecated), do: "bg-orange-500"
  defp lifecycle_color(:decommissioned), do: "bg-red-500"
  defp lifecycle_color(:abandoned), do: "bg-neutral-400"
  defp lifecycle_color(_), do: "bg-neutral-400"
end
