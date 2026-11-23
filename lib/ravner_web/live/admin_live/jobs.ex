defmodule RavnerWeb.AdminLive.Jobs do
  use RavnerWeb, :live_view

  alias Ravner.Repo
  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainMetadata
  import Ecto.Query

  @worker_types %{
    "all" => nil,
    "domain_scan" => "DomainScanWorker",
    "a11y" => "A11yScanWorker",
    "lighthouse" => "LighthouseWorker",
    "uptime" => "UptimeWorker",
    "ssl" => "SslWorker",
    "dispatcher" => "Dispatcher"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, 3000)
    end

    socket =
      socket
      |> assign(:active_tab, :queue)
      |> assign(:show_dispatchers, false)
      |> assign(:worker_filter, "all")
      |> assign(:domain_names, %{})
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
  def handle_event("cancel_job", %{"id" => id}, socket) do
    case Oban.cancel_job(String.to_integer(id)) do
      :ok ->
        {:noreply, fetch_jobs(socket) |> put_flash(:info, "Job cancelled.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_all_executing", _, socket) do
    executing_jobs =
      Oban.Job
      |> where([j], j.state == "executing")
      |> Repo.all()

    cancelled =
      Enum.count(executing_jobs, fn job ->
        case Oban.cancel_job(job.id) do
          :ok -> true
          _ -> false
        end
      end)

    {:noreply,
     socket
     |> fetch_jobs()
     |> put_flash(:info, "Cancelled #{cancelled} executing job(s).")}
  end

  @impl true
  def handle_event("set_worker_filter", %{"filter" => filter}, socket) do
    {:noreply,
     socket
     |> assign(:worker_filter, filter)
     |> fetch_jobs()}
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
    worker_filter = Map.get(@worker_types, socket.assigns.worker_filter)

    query =
      Oban.Job
      |> then(fn q ->
        if socket.assigns.show_dispatchers do
          q
        else
          where(q, [j], not like(j.worker, "%Dispatcher"))
        end
      end)
      |> then(fn q ->
        if worker_filter do
          where(q, [j], like(j.worker, ^"%#{worker_filter}%"))
        else
          q
        end
      end)

    jobs =
      query
      |> order_by([j], desc: j.id)
      |> limit(100)
      |> Repo.all()

    # Resolve domain names for jobs with domain_id in args
    domain_ids =
      jobs
      |> Enum.map(fn job -> job.args["domain_id"] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    domain_names =
      if domain_ids != [] do
        from(d in Domain, where: d.id in ^domain_ids, select: {d.id, d.name})
        |> Repo.all()
        |> Map.new()
      else
        %{}
      end

    stats =
      Oban.Job
      |> group_by([j], j.state)
      |> select([j], {j.state, count(j.id)})
      |> Repo.all()
      |> Enum.into(%{})

    # Count executing by worker type for quick overview
    executing_by_worker =
      Oban.Job
      |> where([j], j.state == "executing")
      |> group_by([j], j.worker)
      |> select([j], {j.worker, count(j.id)})
      |> Repo.all()
      |> Map.new()

    socket
    |> assign(:jobs, jobs)
    |> assign(:stats, stats)
    |> assign(:domain_names, domain_names)
    |> assign(:executing_by_worker, executing_by_worker)
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
