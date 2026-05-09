defmodule RavnerWeb.AdminLive.Jobs do
  use RavnerWeb, :live_view

  alias Ravner.Repo
  alias Ravner.Domains
  alias Ravner.Domains.DomainMetadata
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, 5000)
    end

    socket =
      socket
      |> assign(:active_tab, :queue)
      |> assign(:show_dispatchers, false)
      |> fetch_jobs()
      |> fetch_schedules()

    {:ok, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 5000)

    socket =
      socket
      |> fetch_jobs()
      |> fetch_schedules()

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("toggle_dispatchers", _, socket) do
    socket = 
      socket
      |> assign(:show_dispatchers, !socket.assigns.show_dispatchers)
      |> fetch_jobs()
      
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_job", %{"id" => id}, socket) do
    Oban.Job
    |> Repo.get!(id)
    |> Repo.delete!()

    {:noreply, fetch_jobs(socket)}
  end

  @impl true
  def handle_event("disable_schedule", %{"domain_id" => id}, socket) do
    id = String.to_integer(id)
    
    attrs = %{
      scan_interval_days: nil, 
      heartbeat_interval_minutes: nil,
      http_scan_interval_days: nil,
      dns_scan_interval_days: nil
    }
    
    case Domains.upsert_domain_metadata(id, attrs) do
      {:ok, _} ->
        {:noreply, fetch_schedules(socket) |> put_flash(:info, "Schedules disabled for domain.")}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to disable schedules.")}
    end
  end

  defp fetch_jobs(socket) do
    query = Oban.Job
    
    query = 
      if socket.assigns.show_dispatchers do
        query
      else
        where(query, [j], not like(j.worker, "%Dispatcher"))
      end

    jobs =
      query
      |> order_by([j], desc: j.id)
      |> limit(50)
      |> Repo.all()

    stats =
      Oban.Job
      |> group_by([j], j.state)
      |> select([j], {j.state, count(j.id)})
      |> Repo.all()
      |> Enum.into(%{})

    socket
    |> assign(:jobs, jobs)
    |> assign(:stats, stats)
    |> assign(:page_title, "Background Jobs")
  end

  defp fetch_schedules(socket) do
    schedules =
      from(m in DomainMetadata,
        join: d in assoc(m, :domain),
        where:
          not is_nil(m.scan_interval_days) or 
          not is_nil(m.heartbeat_interval_minutes) or
          not is_nil(m.http_scan_interval_days) or
          not is_nil(m.dns_scan_interval_days),
        order_by: [asc: d.name],
        preload: [domain: d]
      )
      |> Repo.all()

    assign(socket, :schedules, schedules)
  end
end
