defmodule RavnerWeb.AdminLive.Jobs do
  use RavnerWeb, :live_view

  alias Ravner.Repo
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, 5000)
    end

    {:ok, fetch_jobs(socket)}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 5000)
    {:noreply, fetch_jobs(socket)}
  end

  @impl true
  def handle_event("delete_job", %{"id" => id}, socket) do
    Oban.Job
    |> Repo.get!(id)
    |> Repo.delete!()

    {:noreply, fetch_jobs(socket)}
  end

  defp fetch_jobs(socket) do
    jobs =
      Oban.Job
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
end
