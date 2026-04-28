defmodule RavnerWeb.DomainLive.Show do
  use RavnerWeb, :live_view

  alias Ravner.Domains
  alias Ravner.Scans

  # Two-part TLDs for root domain extraction (same logic as Balebos)
  @two_part_tlds ~w(co.uk com.au co.nz co.za com.br co.in org.uk me.uk net.uk co.jp)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, scanning: false, pending_scans: 0, lifecycle_menu_open: false)}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    domain = Domains.get_domain_with_preloads!(id)

    {:noreply,
     socket
     |> assign(:page_title, domain.name)
     |> assign(:domain, domain)
     |> assign(:scan_results, nil)
     |> assign(:scanning, false)
     |> assign(:pending_scans, 0)
     |> assign(:domain_class, compute_domain_class(domain))}
  end

  # ---------------------------------------------------------------------------
  # Scan events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("scan_all", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()

    socket =
      socket
      |> assign(:scanning, true)
      |> assign(:pending_scans, 4)

    Task.start(fn -> send(liveview_pid, {:scan_done, :dnsx, Scans.run_dnsx_scan(domain_id)}) end)

    Task.start(fn ->
      send(liveview_pid, {:scan_done, :httpx, Scans.run_httpx_scan(domain_id)})
    end)

    Task.start(fn -> send(liveview_pid, {:scan_done, :rdap, Scans.run_rdap_scan(domain_id)}) end)

    Task.start(fn ->
      send(liveview_pid, {:scan_done, :subdomains, Scans.run_subdomain_scan(domain_id)})
    end)

    {:noreply, socket}
  end

  def handle_event("toggle_lifecycle_menu", _, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, !socket.assigns.lifecycle_menu_open)}
  end

  def handle_event("close_lifecycle_menu", _, socket) do
    {:noreply, assign(socket, :lifecycle_menu_open, false)}
  end

  def handle_event("set_lifecycle", %{"state" => state}, socket) do
    domain = socket.assigns.domain

    case Domains.update_domain(domain, %{lifecycle_state: state}) do
      {:ok, _} ->
        domain = Domains.get_domain_with_preloads!(domain.id)

        {:noreply,
         socket
         |> assign(:domain, domain)
         |> assign(:lifecycle_menu_open, false)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update lifecycle")}
    end
  end

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

  def handle_event("scan_rdap", _, socket) do
    domain_id = socket.assigns.domain.id
    liveview_pid = self()
    socket = assign(socket, :scanning, true)

    Task.start(fn ->
      result = Scans.run_rdap_scan(domain_id)
      send(liveview_pid, {:scan_done, :rdap, result})
    end)

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Scan completions
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:scan_done, :subdomains, {:ok, results}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    {:noreply,
     socket
     |> finish_scan()
     |> assign(:scan_results, results)
     |> assign(:domain, domain)
     |> assign(:domain_class, compute_domain_class(domain))
     |> put_flash(:info, "Found #{results.found} subdomains (#{results.new} new)")}
  end

  def handle_info({:scan_done, :httpx, {:ok, %{error: kind}}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    label =
      case kind do
        :nxdomain -> "DNS resolution failed (NXDOMAIN)"
        :timeout -> "Connection timed out"
        :tls_error -> "TLS/SSL error"
        :connection_refused -> "Connection refused"
        :connection_closed -> "Connection closed"
        _ -> "Unreachable"
      end

    {:noreply,
     socket
     |> finish_scan()
     |> assign(:domain, domain)
     |> assign(:domain_class, compute_domain_class(domain))
     |> put_flash(:error, "HTTP scan error: #{label}")}
  end

  def handle_info({:scan_done, :httpx, {:ok, _}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    {:noreply,
     socket
     |> finish_scan()
     |> assign(:domain, domain)
     |> assign(:domain_class, compute_domain_class(domain))
     |> put_flash(:info, "HTTP scan completed")}
  end

  def handle_info({:scan_done, :dnsx, {:ok, _}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    {:noreply,
     socket
     |> finish_scan()
     |> assign(:domain, domain)
     |> assign(:domain_class, compute_domain_class(domain))
     |> put_flash(:info, "DNS scan completed")}
  end

  def handle_info({:scan_done, :rdap, {:ok, %{source: source}}}, socket) do
    domain = Domains.get_domain_with_preloads!(socket.assigns.domain.id)

    source_label =
      %{
        "rdap" => "RDAP",
        "whois" => "WHOIS",
        "ns_heuristics" => "NS heuristics",
        "none" => "no data found"
      }[source] || source

    {:noreply,
     socket
     |> finish_scan()
     |> assign(:domain, domain)
     |> assign(:domain_class, compute_domain_class(domain))
     |> put_flash(:info, "Registration scan completed via #{source_label}")}
  end

  def handle_info({:scan_done, _kind, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> finish_scan()
     |> put_flash(:error, reason)}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Decrements the pending scan counter; sets scanning: false when all done
  defp finish_scan(socket) do
    pending = max(0, socket.assigns.pending_scans - 1)
    socket = assign(socket, :pending_scans, pending)

    if pending == 0 do
      assign(socket, :scanning, false)
    else
      socket
    end
  end

  # Compute domain classification from stored metadata (Balebos-style)
  defp compute_domain_class(domain) do
    meta = domain.domain_metadata

    cond do
      is_nil(meta) || is_nil(meta.http_status) ->
        {:not_scanned, nil}

      meta.http_status == 0 ->
        {:scan_error, nil}

      meta.http_status == 200 ->
        case external_redirect_target(domain.name, meta.final_url) do
          nil -> {:ok, nil}
          target -> {:external_redirect, target}
        end

      meta.http_status in 300..399 ->
        target = meta.final_url || "unknown"
        {:redirect, target}

      meta.http_status in 400..499 ->
        {:client_error, meta.http_status}

      meta.http_status in 500..599 ->
        {:server_error, meta.http_status}

      true ->
        {:other, meta.http_status}
    end
  end

  # Returns the external redirect target domain if final_url points outside the current root domain
  defp external_redirect_target(_domain_name, nil), do: nil

  defp external_redirect_target(domain_name, final_url) do
    current_root = extract_root_domain(domain_name)

    final_root =
      final_url
      |> URI.parse()
      |> Map.get(:host, "")
      |> kernel_to_string()
      |> extract_root_domain()

    if final_root != "" && final_root != current_root do
      final_root
    else
      nil
    end
  end

  defp kernel_to_string(nil), do: ""
  defp kernel_to_string(s), do: s

  defp extract_root_domain(host) when is_binary(host) do
    parts = host |> String.replace_prefix("www.", "") |> String.split(".")
    count = length(parts)

    cond do
      count >= 3 && two_part_tld?(parts |> Enum.take(-2) |> Enum.join(".")) ->
        parts |> Enum.take(-3) |> Enum.join(".")

      count >= 2 ->
        parts |> Enum.take(-2) |> Enum.join(".")

      true ->
        host
    end
  end

  defp extract_root_domain(_), do: ""

  defp two_part_tld?(tld), do: tld in @two_part_tlds

  defp lifecycle_color(:active), do: "bg-green-500"
  defp lifecycle_color(:under_review), do: "bg-yellow-500"
  defp lifecycle_color(:deprecated), do: "bg-orange-500"
  defp lifecycle_color(:decommissioned), do: "bg-red-500"
  defp lifecycle_color(:abandoned), do: "bg-neutral-400"
  defp lifecycle_color(_), do: "bg-neutral-400"

  defp lifecycle_options do
    [
      {:active, "Active", "bg-green-500"},
      {:under_review, "Under review", "bg-yellow-500"},
      {:deprecated, "Deprecated", "bg-orange-500"},
      {:decommissioned, "Decommissioned", "bg-red-500"},
      {:abandoned, "Abandoned", "bg-neutral-400"}
    ]
  end
end
