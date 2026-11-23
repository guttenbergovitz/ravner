defmodule RavnerWeb.AdminLive.Certificates do
  @moduledoc """
  LiveView for administrative SSL certificate overview.
  """
  use RavnerWeb, :live_view

  alias Ravner.Repo
  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainMetadata
  import Ecto.Query

  @operational_states Domain.operational_states()

  @impl true
  def mount(_params, _session, socket) do
    if admin?(socket.assigns.current_scope) do
      {:ok,
       socket
       |> assign(:page_title, "SSL Certificates")
       |> fetch_certificates()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Admin access required")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    certs = socket.assigns.certificates
    now = DateTime.utc_now()

    csv =
      ["Domain,Status,Days Remaining,Expires,Issuer,Valid From"]
      |> Enum.concat(
        Enum.map(certs, fn cert ->
          expired = cert.days_remaining != nil && cert.days_remaining < 0

          status =
            if expired do
              "Expired"
            else
              "#{cert.days_remaining} days"
            end

          expires =
            if cert.valid_until, do: Calendar.strftime(cert.valid_until, "%Y-%m-%d"), else: ""

          valid_from =
            if cert.valid_from, do: Calendar.strftime(cert.valid_from, "%Y-%m-%d"), else: ""

          issuer = escape_csv_field(cert.issuer || "")
          name = escape_csv_field(cert.name)

          "#{name},#{status},#{cert.days_remaining || ""},#{expires},#{issuer},#{valid_from}"
        end)
      )
      |> Enum.join("\n")

    socket =
      push_event(socket, "download_csv", %{
        filename: "certificates-#{DateTime.to_iso8601(now) |> String.slice(0, 10)}.csv",
        content: csv <> "\n"
      })

    {:noreply, socket}
  end

  @impl true
  def handle_event("scan_expired", _params, socket) do
    ids =
      socket.assigns.certificates
      |> Enum.filter(fn c -> c.days_remaining != nil and c.days_remaining < 0 end)
      |> Enum.map(& &1.id)

    if ids == [] do
      {:noreply, put_flash(socket, :info, "No expired certificates to scan")}
    else
      jobs =
        Enum.map(ids, fn id ->
          Ravner.Workers.ScanWorker.new(%{domain_id: id, scan_type: "ssl"}, queue: :ssl_checks)
        end)

      Oban.insert_all(jobs)

      {:noreply,
       put_flash(
         socket,
         :info,
         "Queued SSL scan for #{length(ids)} expired domain(s)"
       )}
    end
  end

  @impl true
  def handle_event("scan_expiring_30d", _params, socket) do
    ids =
      socket.assigns.certificates
      |> Enum.filter(fn c ->
        c.days_remaining != nil and c.days_remaining >= 0 and c.days_remaining <= 30
      end)
      |> Enum.map(& &1.id)

    if ids == [] do
      {:noreply, put_flash(socket, :info, "No certificates expiring within 30 days to scan")}
    else
      jobs =
        Enum.map(ids, fn id ->
          Ravner.Workers.ScanWorker.new(%{domain_id: id, scan_type: "ssl"}, queue: :ssl_checks)
        end)

      Oban.insert_all(jobs)

      {:noreply,
       put_flash(
         socket,
         :info,
         "Queued SSL scan for #{length(ids)} domain(s) expiring within 30 days"
       )}
    end
  end

  @impl true
  def handle_event("bulk_scan", %{"limit" => limit}, socket) do
    limit = String.to_integer(limit)

    ids =
      socket.assigns.certificates
      |> Enum.take(limit)
      |> Enum.map(& &1.id)

    jobs =
      Enum.map(ids, fn id ->
        Ravner.Workers.ScanWorker.new(%{domain_id: id, scan_type: "ssl"}, queue: :ssl_checks)
      end)

    Oban.insert_all(jobs)

    socket =
      put_flash(
        socket,
        :info,
        "Queued SSL scan for #{length(ids)} domain(s)"
      )

    {:noreply, socket}
  end

  defp fetch_certificates(socket) do
    now = DateTime.utc_now()

    query =
      from(m in DomainMetadata,
        join: d in Domain,
        on: m.domain_id == d.id,
        where: d.lifecycle_state in ^@operational_states,
        where: not is_nil(m.ssl_valid_until),
        order_by: [asc: m.ssl_valid_until],
        select: %{
          id: d.id,
          name: d.name,
          issuer: m.ssl_issuer,
          valid_from: m.ssl_valid_from,
          valid_until: m.ssl_valid_until,
          days_remaining: m.ssl_days_remaining
        }
      )

    certs =
      Repo.all(query)
      |> Enum.map(fn cert ->
        days =
          if cert.valid_until do
            DateTime.diff(cert.valid_until, now, :day)
          else
            cert.days_remaining
          end

        Map.put(cert, :days_remaining, days)
      end)

    expired_count =
      Enum.count(certs, fn c -> c.days_remaining != nil and c.days_remaining < 0 end)

    expiring_30d_count =
      Enum.count(certs, fn c ->
        c.days_remaining != nil and c.days_remaining >= 0 and c.days_remaining <= 30
      end)

    socket
    |> assign(:certificates, certs)
    |> assign(:expired_count, expired_count)
    |> assign(:expiring_30d_count, expiring_30d_count)
  end

  defp escape_csv_field(nil), do: ""

  defp escape_csv_field(field) do
    field = to_string(field)

    if String.contains?(field, [",", "\"", "\n"]) do
      escaped = String.replace(field, "\"", "\"\"")
      "\"#{escaped}\""
    else
      field
    end
  end

  defp admin?(nil), do: false
  defp admin?(scope), do: scope.user && scope.user.role == :admin
end
