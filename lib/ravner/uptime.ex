defmodule Ravner.Uptime do
  @moduledoc """
  Context for uptime monitoring: heartbeat history, downtime detection, reporting.
  """

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Uptime.HeartbeatCheck
  alias Ravner.Uptime.DowntimeWindow
  alias Ravner.Uptime.DowntimeNote

  @default_threshold 2

  @doc """
  Records a heartbeat check result and evaluates downtime state.
  Returns {:ok, check} or {:error, changeset}.
  """
  def record_check(domain_id, attrs) do
    checked_at =
      (attrs[:checked_at] || DateTime.utc_now())
      |> DateTime.truncate(:second)

    check = %HeartbeatCheck{
      domain_id: domain_id,
      checked_at: checked_at,
      is_up: attrs[:is_up],
      response_time_ms: attrs[:response_time_ms],
      error_reason: attrs[:error_reason]
    }

    case Repo.insert(check) do
      {:ok, check} ->
        evaluate_downtime(domain_id, check)
        {:ok, check}

      error ->
        error
    end
  end

  defp evaluate_downtime(domain_id, %HeartbeatCheck{is_up: true}) do
    close_open_window(domain_id)
  end

  defp evaluate_downtime(domain_id, %HeartbeatCheck{is_up: false}) do
    threshold = get_threshold(domain_id)

    unless has_open_window?(domain_id) do
      consecutive = count_consecutive_failures(domain_id)

      if consecutive >= threshold do
        earliest = get_earliest_consecutive_failure(domain_id, consecutive)

        window =
          %DowntimeWindow{
            domain_id: domain_id,
            started_at: earliest,
            failure_threshold_used: threshold
          }
          |> Repo.insert!()

        Ravner.Uptime.Notifications.dispatch("incident_open", window)
      end
    end
  end

  defp has_open_window?(domain_id) do
    DowntimeWindow
    |> where(domain_id: ^domain_id)
    |> where([w], is_nil(w.ended_at))
    |> Repo.exists?()
  end

  defp close_open_window(domain_id) do
    now = DateTime.utc_now(:second)

    {updated, _} =
      from(w in DowntimeWindow,
        where: w.domain_id == ^domain_id,
        where: is_nil(w.ended_at),
        update: [
          set: [
            ended_at: ^now,
            duration_seconds: fragment("EXTRACT(EPOCH FROM ? - started_at)::integer", ^now)
          ]
        ]
      )
      |> Repo.update_all([])

    if updated > 0 do
      window =
        DowntimeWindow
        |> where(domain_id: ^domain_id)
        |> where([w], w.ended_at == ^now)
        |> order_by(desc: :started_at)
        |> limit(1)
        |> Repo.one()

      if window, do: Ravner.Uptime.Notifications.dispatch("incident_resolved", window)
    end
  end

  defp count_consecutive_failures(domain_id) do
    HeartbeatCheck
    |> where(domain_id: ^domain_id)
    |> order_by(desc: :checked_at)
    |> select([c], c.is_up)
    |> limit(20)
    |> Repo.all()
    |> Enum.take_while(&(!&1))
    |> length()
  end

  defp get_earliest_consecutive_failure(domain_id, count) do
    HeartbeatCheck
    |> where(domain_id: ^domain_id)
    |> order_by(desc: :checked_at)
    |> limit(^count)
    |> select([c], c.checked_at)
    |> Repo.all()
    |> List.last()
  end

  # ponytail: threshold hardcoded; upgrade path: per-domain config in uptime_monitors table
  defp get_threshold(_domain_id), do: @default_threshold

  # --- Query helpers for UI ---

  @doc """
  Returns all domains with heartbeat monitoring enabled and their current status.
  """
  def list_monitored_domains do
    from(m in Ravner.Domains.DomainMetadata,
      join: d in assoc(m, :domain),
      where: not is_nil(m.heartbeat_interval_minutes),
      where: d.technical_status != :redirect,
      order_by: [asc: d.name],
      preload: [domain: d],
      select: m
    )
    |> Repo.all()
  end

  @doc """
  Returns open downtime window for a domain (if any).
  """
  def open_downtime(domain_id) do
    DowntimeWindow
    |> where(domain_id: ^domain_id)
    |> where([w], is_nil(w.ended_at))
    |> Repo.one()
  end

  @doc """
  Returns downtime windows for a domain within a time range.
  """
  def downtime_windows(domain_id, from_dt, to_dt) do
    DowntimeWindow
    |> where(domain_id: ^domain_id)
    |> where([w], w.started_at >= ^from_dt)
    |> where([w], w.started_at <= ^to_dt or is_nil(w.ended_at))
    |> order_by(desc: :started_at)
    |> Repo.all()
  end

  @doc """
  Computes uptime percentage for a domain in a time range.
  """
  def uptime_percent(domain_id, from_dt, to_dt) do
    total_seconds = DateTime.diff(to_dt, from_dt, :second)

    downtime_seconds =
      downtime_windows(domain_id, from_dt, to_dt)
      |> Enum.reduce(0, fn w, acc ->
        window_start = max_dt(w.started_at, from_dt)
        window_end = min_dt(w.ended_at || to_dt, to_dt)
        acc + max(0, DateTime.diff(window_end, window_start, :second))
      end)

    if total_seconds > 0 do
      Float.round((total_seconds - downtime_seconds) / total_seconds * 100, 2)
    else
      100.0
    end
  end

  defp max_dt(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp min_dt(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  @doc """
  Returns recent heartbeat checks for a domain (for timeline view).
  """
  def recent_checks(domain_id, limit \\ 60) do
    HeartbeatCheck
    |> where(domain_id: ^domain_id)
    |> order_by(desc: :checked_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # --- Downtime Notes ---

  def list_notes(downtime_window_id) do
    DowntimeNote
    |> where(downtime_window_id: ^downtime_window_id)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
    |> Repo.preload(:author)
  end

  def create_note(attrs) do
    %DowntimeNote{}
    |> DowntimeNote.changeset(attrs)
    |> Repo.insert()
  end

  def update_note(%DowntimeNote{} = note, attrs) do
    note
    |> DowntimeNote.changeset(attrs)
    |> Repo.update()
  end

  def delete_note(%DowntimeNote{} = note), do: Repo.delete(note)

  def get_note!(id), do: Repo.get!(DowntimeNote, id)
end
