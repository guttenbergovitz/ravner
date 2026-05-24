defmodule RavnerWeb.AdminLive.DomainRegistrations do
  @moduledoc """
  LiveView for administrative domain registration overview.
  """
  use RavnerWeb, :live_view

  alias Ravner.Repo
  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainMetadata
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    if admin?(socket.assigns.current_scope) do
      {:ok,
       socket
       |> assign(:page_title, "Domain Registrations")
       |> fetch_domains()}
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
    domains = socket.assigns.domains
    now = DateTime.utc_now()

    csv =
      ["Domain,Status,Days Remaining,Expires,Registrar,Registered"]
      |> Enum.concat(
        Enum.map(domains, fn d ->
          expired = d.days_remaining != nil && d.days_remaining < 0

          status =
            if expired do
              "Expired"
            else
              "#{d.days_remaining} days"
            end

          expires =
            if d.expiration_date,
              do: Calendar.strftime(d.expiration_date, "%Y-%m-%d"),
              else: ""

          registered =
            if d.registration_date,
              do: Calendar.strftime(d.registration_date, "%Y-%m-%d"),
              else: ""

          registrar = escape_csv_field(d.registrar || "")
          name = escape_csv_field(d.name)

          "#{name},#{status},#{d.days_remaining || ""},#{expires},#{registrar},#{registered}"
        end)
      )
      |> Enum.join("\n")

    socket =
      push_event(socket, "download_csv", %{
        filename: "domain-registrations-#{DateTime.to_iso8601(now) |> String.slice(0, 10)}.csv",
        content: csv <> "\n"
      })

    {:noreply, socket}
  end

  @impl true
  def handle_event("bulk_scan", %{"limit" => limit}, socket) do
    limit = String.to_integer(limit)

    ids =
      socket.assigns.domains
      |> Enum.take(limit)
      |> Enum.map(& &1.id)

    jobs =
      Enum.map(ids, fn id ->
        Ravner.Workers.ScanWorker.new(%{domain_id: id, scan_type: "rdap"})
      end)

    Oban.insert_all(jobs)

    socket =
      put_flash(
        socket,
        :info,
        "Queued RDAP scan for #{length(ids)} domain(s)"
      )

    {:noreply, socket}
  end

  defp fetch_domains(socket) do
    now = DateTime.utc_now()

    domains =
      Repo.all(
        from(m in DomainMetadata,
          join: d in Domain,
          on: m.domain_id == d.id,
          where: not is_nil(m.expiration_date),
          order_by: [asc: m.expiration_date],
          select: %{
            id: d.id,
            name: d.name,
            registrar: m.registrar,
            registration_date: m.registration_date,
            expiration_date: m.expiration_date
          }
        )
      )
      |> Enum.map(fn d ->
        days_remaining =
          if d.expiration_date do
            DateTime.diff(d.expiration_date, now, :day)
          else
            nil
          end

        Map.put(d, :days_remaining, days_remaining)
      end)

    assign(socket, :domains, domains)
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
