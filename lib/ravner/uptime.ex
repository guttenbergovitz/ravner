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

  # --- Chart data helpers ---

  @doc """
  Returns daily uptime stats for the last N days.
  Each entry: %{date: Date.t(), uptime_percent: float(), incidents: integer(), avg_response_ms: integer() | nil}
  """
  def daily_stats(domain_id, days \\ 30) do
    today = Date.utc_today()
    start_date = Date.add(today, -(days - 1))

    # Get all checks in the range
    from_dt = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.utc_now()

    checks_by_day =
      HeartbeatCheck
      |> where(domain_id: ^domain_id)
      |> where([c], c.checked_at >= ^from_dt)
      |> select([c], %{
        date: fragment("(?::date)", c.checked_at),
        is_up: c.is_up,
        response_time_ms: c.response_time_ms
      })
      |> Repo.all()
      |> Enum.group_by(& &1.date)

    # Get downtime windows overlapping the range
    windows = downtime_windows(domain_id, from_dt, to_dt)

    # Build a stat for each day
    Date.range(start_date, today)
    |> Enum.map(fn date ->
      day_checks = Map.get(checks_by_day, date, [])
      total = length(day_checks)
      up_count = Enum.count(day_checks, & &1.is_up)

      uptime_pct =
        if total > 0, do: Float.round(up_count / total * 100, 1), else: nil

      response_times =
        day_checks
        |> Enum.map(& &1.response_time_ms)
        |> Enum.reject(&is_nil/1)

      avg_response =
        if response_times != [],
          do: div(Enum.sum(response_times), length(response_times)),
          else: nil

      # Count incidents that started on this day
      day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      day_end = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

      incidents =
        Enum.count(windows, fn w ->
          DateTime.compare(w.started_at, day_start) != :lt &&
            DateTime.compare(w.started_at, day_end) != :gt
        end)

      %{
        date: date,
        uptime_percent: uptime_pct,
        incidents: incidents,
        avg_response_ms: avg_response
      }
    end)
  end

  @doc """
  Returns response time data points for charting.
  List of %{at: DateTime.t(), ms: integer()} ordered ascending by time.
  """
  def response_time_series(domain_id, hours \\ 24) do
    since = DateTime.add(DateTime.utc_now(), -hours, :hour)

    HeartbeatCheck
    |> where(domain_id: ^domain_id)
    |> where([c], c.checked_at >= ^since)
    |> where([c], not is_nil(c.response_time_ms))
    |> order_by(asc: :checked_at)
    |> select([c], %{at: c.checked_at, ms: c.response_time_ms})
    |> Repo.all()
  end

  @doc """
  Returns uptime percentage per day for the last N days.
  Lightweight version of daily_stats for the uptime bar visualization.
  List of %{date: Date.t(), percent: float()}
  """
  def uptime_bar_data(domain_id, days \\ 30) do
    daily_stats(domain_id, days)
    |> Enum.map(fn %{date: date, uptime_percent: pct} ->
      %{date: date, percent: pct}
    end)
  end

  @doc """
  Returns hourly stats for a specific day (24 entries, one per hour).
  Each: %{hour: 0..23, checks: int, up: int, uptime_percent: float | nil, avg_response_ms: int | nil}
  """
  def hourly_stats(domain_id, %Date{} = date) do
    day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    day_end = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

    checks =
      HeartbeatCheck
      |> where(domain_id: ^domain_id)
      |> where([c], c.checked_at >= ^day_start and c.checked_at <= ^day_end)
      |> select([c], %{
        hour: fragment("EXTRACT(HOUR FROM ?)::integer", c.checked_at),
        is_up: c.is_up,
        response_time_ms: c.response_time_ms
      })
      |> Repo.all()
      |> Enum.group_by(& &1.hour)

    for hour <- 0..23 do
      hour_checks = Map.get(checks, hour, [])
      total = length(hour_checks)
      up_count = Enum.count(hour_checks, & &1.is_up)

      response_times =
        hour_checks
        |> Enum.map(& &1.response_time_ms)
        |> Enum.reject(&is_nil/1)

      %{
        hour: hour,
        checks: total,
        up: up_count,
        uptime_percent: if(total > 0, do: Float.round(up_count / total * 100, 1), else: nil),
        avg_response_ms:
          if(response_times != [], do: div(Enum.sum(response_times), length(response_times)), else: nil)
      }
    end
  end

  @doc """
  Returns a human-readable status summary for a domain.
  Returns %{text: String.t(), since: DateTime.t() | nil, last_incident: map() | nil}
  """
  def status_summary(domain_id) do
    open = open_downtime(domain_id)

    if open do
      duration = DateTime.diff(DateTime.utc_now(), open.started_at, :second)

      %{
        status: :down,
        text: "Down since #{Calendar.strftime(open.started_at, "%H:%M UTC")} (#{humanize_duration(duration)} ago)",
        since: open.started_at,
        last_incident: nil
      }
    else
      # Find last closed incident
      last_window =
        DowntimeWindow
        |> where(domain_id: ^domain_id)
        |> where([w], not is_nil(w.ended_at))
        |> order_by(desc: :ended_at)
        |> limit(1)
        |> Repo.one()

      # Find streak of consecutive up checks
      last_down_check =
        HeartbeatCheck
        |> where(domain_id: ^domain_id)
        |> where([c], c.is_up == false)
        |> order_by(desc: :checked_at)
        |> limit(1)
        |> select([c], c.checked_at)
        |> Repo.one()

      up_since = last_down_check || get_first_check_time(domain_id)

      up_duration =
        if up_since do
          DateTime.diff(DateTime.utc_now(), up_since, :second)
        else
          nil
        end

      text =
        cond do
          is_nil(up_since) ->
            "No monitoring data collected yet"

          last_window ->
            ago = DateTime.diff(DateTime.utc_now(), last_window.ended_at, :second)

            "Running smoothly for #{humanize_duration(up_duration)}. Last incident #{humanize_duration(ago)} ago, lasted #{humanize_duration(last_window.duration_seconds)}."

          true ->
            "Running smoothly for #{humanize_duration(up_duration)}. No incidents recorded."
        end

      %{
        status: :up,
        text: text,
        since: up_since,
        last_incident: last_window && %{ended_at: last_window.ended_at, duration: last_window.duration_seconds}
      }
    end
  end

  defp get_first_check_time(domain_id) do
    HeartbeatCheck
    |> where(domain_id: ^domain_id)
    |> order_by(asc: :checked_at)
    |> limit(1)
    |> select([c], c.checked_at)
    |> Repo.one()
  end

  defp humanize_duration(nil), do: "—"
  defp humanize_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp humanize_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)} min"

  defp humanize_duration(seconds) when seconds < 86400 do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    if mins > 0, do: "#{hours}h #{mins}min", else: "#{hours}h"
  end

  defp humanize_duration(seconds) do
    days = div(seconds, 86400)
    hours = div(rem(seconds, 86400), 3600)
    if hours > 0, do: "#{days}d #{hours}h", else: "#{days}d"
  end

  # --- Admin actions ---

  @doc """
  Purges all monitoring data for a domain: heartbeat checks, downtime windows, and notes.
  Use to clear false positives from misconfigured checks.
  Returns {checks_deleted, windows_deleted}.
  """
  def purge_domain_data(domain_id) do
    # Delete notes first (FK constraint)
    from(n in DowntimeNote,
      join: w in DowntimeWindow,
      on: n.downtime_window_id == w.id,
      where: w.domain_id == ^domain_id
    )
    |> Repo.delete_all()

    {windows, _} =
      DowntimeWindow
      |> where(domain_id: ^domain_id)
      |> Repo.delete_all()

    {checks, _} =
      HeartbeatCheck
      |> where(domain_id: ^domain_id)
      |> Repo.delete_all()

    {checks, windows}
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
