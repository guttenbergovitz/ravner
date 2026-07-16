# Uptime Monitoring & Alerting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend Ravner's existing heartbeat mechanism into a full uptime monitoring system with history, downtime detection, notifications (email + SMS), a dedicated status tab, and governance reporting.

**Architecture:** Build on the existing HeartbeatWorker/Dispatcher pattern. Add a `heartbeat_checks` table for history, compute `downtime_windows` eagerly on state flips, and trigger notifications via a new Oban worker. SMS uses a behaviour-based adapter pattern (AwsSns/Twilio/Log). Notification policies resolve at three levels: per-domain > group > global.

**Tech Stack:** Elixir, Phoenix LiveView, Oban, Ecto, Swoosh (email), ExAws.SNS or Req-based AWS calls (SMS), PostgreSQL.

---

## File Map

### Phase 1 — History + Downtime Detection


| File | Action | Responsibility |
|------|--------|----------------|
| `priv/repo/migrations/TIMESTAMP_create_heartbeat_checks.exs` | Create | heartbeat_checks table |
| `priv/repo/migrations/TIMESTAMP_create_downtime_windows.exs` | Create | downtime_windows table |
| `lib/ravner/uptime/heartbeat_check.ex` | Create | Ecto schema for heartbeat_checks |
| `lib/ravner/uptime/downtime_window.ex` | Create | Ecto schema for downtime_windows |
| `lib/ravner/uptime.ex` | Create | Context module — queries, downtime logic |
| `lib/ravner/workers/heartbeat_worker.ex` | Modify | Persist check + trigger downtime detection |
| `lib/ravner/workers/heartbeat_retention_worker.ex` | Create | Oban cron to prune old checks |
| `config/config.exs` | Modify | Add retention worker to cron |

### Phase 2 — Status Tab (UI)

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/ravner_web/live/admin_live/uptime.ex` | Create | Status page LiveView |
| `lib/ravner_web/live/admin_live/uptime.html.heex` | Create | Status page template |
| `lib/ravner_web/live/admin_live/uptime_report.ex` | Create | Report LiveView |
| `lib/ravner_web/live/admin_live/uptime_report.html.heex` | Create | Report template |
| `lib/ravner_web/router.ex` | Modify | Add /admin/uptime routes |
| `lib/ravner_web/components/layouts/root.html.heex` | Modify | Add Uptime nav link |

### Phase 3 — Notification System

| File | Action | Responsibility |
|------|--------|----------------|
| `priv/repo/migrations/TIMESTAMP_create_notification_tables.exs` | Create | policies, groups, recipients, deliveries |
| `lib/ravner/uptime/notification_policy.ex` | Create | Ecto schema |
| `lib/ravner/uptime/notification_group.ex` | Create | Ecto schema |
| `lib/ravner/uptime/notification_recipient.ex` | Create | Ecto schema |
| `lib/ravner/uptime/notification_delivery.ex` | Create | Ecto schema (idempotency) |
| `lib/ravner/uptime/notifications.ex` | Create | Notification dispatch logic |
| `lib/ravner/uptime/sms_adapter.ex` | Create | Behaviour definition |
| `lib/ravner/uptime/sms_adapters/log.ex` | Create | Dev/test adapter |
| `lib/ravner/uptime/sms_adapters/aws_sns.ex` | Create | AWS SNS adapter |
| `lib/ravner/uptime/sms_adapters/twilio.ex` | Create | Twilio adapter |
| `lib/ravner/uptime/uptime_notifier.ex` | Create | Email templates (Swoosh) |
| `lib/ravner/workers/uptime_notification_worker.ex` | Create | Oban worker for async delivery |
| `config/config.exs` | Modify | Add uptime notification config |

### Phase 4 — Reports + Notes

| File | Action | Responsibility |
|------|--------|----------------|
| `priv/repo/migrations/TIMESTAMP_create_downtime_notes.exs` | Create | downtime_notes table |
| `lib/ravner/uptime/downtime_note.ex` | Create | Ecto schema |
| `lib/ravner_web/live/admin_live/uptime_report.ex` | Modify | Add detail + notes |
| `lib/ravner_web/live/admin_live/uptime_report.html.heex` | Modify | Render notes UI |

---


## Task 1: Create heartbeat_checks migration and schema

**Files:**
- Create: `priv/repo/migrations/YYYYMMDDHHMMSS_create_heartbeat_checks.exs`
- Create: `lib/ravner/uptime/heartbeat_check.ex`

- [ ] **Step 1: Generate migration**

Run: `mix ecto.gen.migration create_heartbeat_checks`

- [ ] **Step 2: Write the migration**

```elixir
defmodule Ravner.Repo.Migrations.CreateHeartbeatChecks do
  use Ecto.Migration

  def change do
    create table(:heartbeat_checks) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :checked_at, :utc_datetime, null: false
      add :is_up, :boolean, null: false
      add :response_time_ms, :integer
      add :error_reason, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:heartbeat_checks, [:domain_id, :checked_at],
      order: [checked_at: :desc])
    create index(:heartbeat_checks, [:checked_at])
  end
end
```

- [ ] **Step 3: Write the Ecto schema**

Create `lib/ravner/uptime/heartbeat_check.ex`:

```elixir
defmodule Ravner.Uptime.HeartbeatCheck do
  use Ecto.Schema

  schema "heartbeat_checks" do
    field :checked_at, :utc_datetime
    field :is_up, :boolean
    field :response_time_ms, :integer
    field :error_reason, :string

    belongs_to :domain, Ravner.Domains.Domain

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
```

- [ ] **Step 4: Run migration**

Run: `mix ecto.migrate`
Expected: Migration succeeds, table created.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/*_create_heartbeat_checks.exs lib/ravner/uptime/heartbeat_check.ex
git commit -m "feat(uptime): add heartbeat_checks table and schema"
```

---


## Task 2: Create downtime_windows migration and schema

**Files:**
- Create: `priv/repo/migrations/YYYYMMDDHHMMSS_create_downtime_windows.exs`
- Create: `lib/ravner/uptime/downtime_window.ex`

- [ ] **Step 1: Generate migration**

Run: `mix ecto.gen.migration create_downtime_windows`

- [ ] **Step 2: Write the migration**

```elixir
defmodule Ravner.Repo.Migrations.CreateDowntimeWindows do
  use Ecto.Migration

  def change do
    create table(:downtime_windows) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      add :duration_seconds, :integer
      add :failure_threshold_used, :integer, null: false, default: 2

      timestamps(type: :utc_datetime)
    end

    create index(:downtime_windows, [:domain_id, :started_at],
      order: [started_at: :desc])
    create index(:downtime_windows, [:domain_id],
      where: "ended_at IS NULL", name: :downtime_windows_open_idx)
  end
end
```

- [ ] **Step 3: Write the Ecto schema**

Create `lib/ravner/uptime/downtime_window.ex`:

```elixir
defmodule Ravner.Uptime.DowntimeWindow do
  use Ecto.Schema

  schema "downtime_windows" do
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :duration_seconds, :integer
    field :failure_threshold_used, :integer, default: 2

    belongs_to :domain, Ravner.Domains.Domain

    has_many :notes, Ravner.Uptime.DowntimeNote

    timestamps(type: :utc_datetime)
  end
end
```

- [ ] **Step 4: Run migration**

Run: `mix ecto.migrate`

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/*_create_downtime_windows.exs lib/ravner/uptime/downtime_window.ex
git commit -m "feat(uptime): add downtime_windows table and schema"
```

---


## Task 3: Create Uptime context module with downtime detection

**Files:**
- Create: `lib/ravner/uptime.ex`
- Test: `test/ravner/uptime_test.exs`

- [ ] **Step 1: Write failing test for downtime detection**

Create `test/ravner/uptime_test.exs`:

```elixir
defmodule Ravner.UptimeTest do
  use Ravner.DataCase, async: true

  alias Ravner.Uptime
  alias Ravner.Uptime.DowntimeWindow

  describe "record_check/2 downtime detection" do
    setup do
      # Create a domain via the existing factory/fixture
      domain = insert_domain("test.example.com")
      %{domain: domain}
    end

    test "does not open downtime on first failure", %{domain: domain} do
      Uptime.record_check(domain.id, %{is_up: false, checked_at: DateTime.utc_now()})

      assert Repo.aggregate(DowntimeWindow, :count) == 0
    end

    test "opens downtime after 2 consecutive failures (default threshold)", %{domain: domain} do
      now = DateTime.utc_now()
      t1 = DateTime.add(now, -60, :second)
      t2 = now

      Uptime.record_check(domain.id, %{is_up: false, checked_at: t1})
      Uptime.record_check(domain.id, %{is_up: false, checked_at: t2})

      assert [%DowntimeWindow{ended_at: nil}] =
               Repo.all(DowntimeWindow)
    end

    test "closes downtime on recovery", %{domain: domain} do
      now = DateTime.utc_now()
      t1 = DateTime.add(now, -120, :second)
      t2 = DateTime.add(now, -60, :second)
      t3 = now

      Uptime.record_check(domain.id, %{is_up: false, checked_at: t1})
      Uptime.record_check(domain.id, %{is_up: false, checked_at: t2})
      Uptime.record_check(domain.id, %{is_up: true, checked_at: t3})

      assert [%DowntimeWindow{ended_at: ended}] = Repo.all(DowntimeWindow)
      assert ended != nil
    end

    test "does not open duplicate downtime if already open", %{domain: domain} do
      now = DateTime.utc_now()

      for i <- 0..4 do
        t = DateTime.add(now, -300 + i * 60, :second)
        Uptime.record_check(domain.id, %{is_up: false, checked_at: t})
      end

      assert Repo.aggregate(DowntimeWindow, :count) == 1
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ravner/uptime_test.exs`
Expected: Compilation error — `Ravner.Uptime` module doesn't exist.

- [ ] **Step 3: Implement Uptime context**

Create `lib/ravner/uptime.ex`:

```elixir
defmodule Ravner.Uptime do
  @moduledoc """
  Context for uptime monitoring: heartbeat history, downtime detection, reporting.
  """

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Uptime.HeartbeatCheck
  alias Ravner.Uptime.DowntimeWindow

  @default_threshold 2

  @doc """
  Records a heartbeat check result and evaluates downtime state.
  Returns {:ok, check} or {:error, changeset}.
  """
  def record_check(domain_id, attrs) do
    check = %HeartbeatCheck{
      domain_id: domain_id,
      checked_at: attrs[:checked_at] || DateTime.utc_now(),
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
    # Recovery: close any open downtime window
    close_open_window(domain_id)
  end

  defp evaluate_downtime(domain_id, %HeartbeatCheck{is_up: false, checked_at: checked_at}) do
    # Failure: check if threshold reached and no open window exists
    threshold = get_threshold(domain_id)

    unless has_open_window?(domain_id) do
      consecutive = count_consecutive_failures(domain_id)

      if consecutive >= threshold do
        # Open a new downtime window; started_at = earliest failure in this run
        earliest = get_earliest_consecutive_failure(domain_id, consecutive)

        %DowntimeWindow{
          domain_id: domain_id,
          started_at: earliest,
          failure_threshold_used: threshold
        }
        |> Repo.insert!()
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

    DowntimeWindow
    |> where(domain_id: ^domain_id)
    |> where([w], is_nil(w.ended_at))
    |> Repo.update_all(
      set: [
        ended_at: now,
        duration_seconds:
          {:fragment, "EXTRACT(EPOCH FROM ? - started_at)::integer", ^now}
      ]
    )
    # ponytail: update_all with fragment avoids loading record; duration computed in SQL
  end

  defp count_consecutive_failures(domain_id) do
    # Count most recent consecutive is_up=false checks
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

  # ponytail: threshold hardcoded for now; upgrade path: per-domain config
  # in a future uptime_monitors table or domain_metadata field
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
  def downtime_windows(domain_id, from, to) do
    DowntimeWindow
    |> where(domain_id: ^domain_id)
    |> where([w], w.started_at >= ^from)
    |> where([w], w.started_at <= ^to or is_nil(w.ended_at))
    |> order_by(desc: :started_at)
    |> Repo.all()
  end

  @doc """
  Computes uptime percentage for a domain in a time range.
  """
  def uptime_percent(domain_id, from, to) do
    total_seconds = DateTime.diff(to, from, :second)

    downtime_seconds =
      downtime_windows(domain_id, from, to)
      |> Enum.reduce(0, fn w, acc ->
        window_start = max_dt(w.started_at, from)
        window_end = min_dt(w.ended_at || to, to)
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
end
```

- [ ] **Step 4: Add test helper for domain creation**

In `test/ravner/uptime_test.exs`, add at the top of the module (after `use Ravner.DataCase`):

```elixir
  # Helper: insert a minimal domain for testing
  defp insert_domain(name) do
    {:ok, domain} =
      %Ravner.Domains.Domain{}
      |> Ecto.Changeset.change(%{name: name, technical_status: :live})
      |> Ravner.Repo.insert()

    domain
  end
```

Note: Adapt this if there's an existing test factory. Check `test/support/` for domain fixtures.

- [ ] **Step 5: Fix the `close_open_window` SQL fragment**

The `Repo.update_all` with a dynamic duration needs proper Ecto fragment syntax:

```elixir
  defp close_open_window(domain_id) do
    now = DateTime.utc_now(:second)

    from(w in DowntimeWindow,
      where: w.domain_id == ^domain_id,
      where: is_nil(w.ended_at),
      update: [set: [
        ended_at: ^now,
        duration_seconds: fragment("EXTRACT(EPOCH FROM ? - started_at)::integer", ^now)
      ]]
    )
    |> Repo.update_all([])
  end
```

- [ ] **Step 6: Run tests**

Run: `mix test test/ravner/uptime_test.exs`
Expected: All 4 tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/ravner/uptime.ex test/ravner/uptime_test.exs
git commit -m "feat(uptime): add Uptime context with downtime detection logic"
```

---


## Task 4: Modify HeartbeatWorker to persist checks

**Files:**
- Modify: `lib/ravner/workers/heartbeat_worker.ex`

- [ ] **Step 1: Update HeartbeatWorker to call Uptime.record_check**

Replace the existing `perform/1` body:

```elixir
defmodule Ravner.Workers.HeartbeatWorker do
  @moduledoc """
  A fast HTTP GET/HEAD ping to determine if a domain is up.
  Persists result to heartbeat_checks and evaluates downtime state.
  """
  use Oban.Worker, queue: :heartbeats

  alias Ravner.Domains
  alias Ravner.Uptime
  alias Ravner.SystemCommand
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain_id" => domain_id}}) do
    domain = Domains.get_domain!(domain_id)
    started_at = System.monotonic_time(:millisecond)

    args = [
      "-silent",
      "-status-code",
      "-timeout",
      "5",
      "-u",
      domain.name
    ]

    {is_up, error_reason} =
      case SystemCommand.run_with_timeout("httpx", args, 10_000) do
        {:ok, %{exit_code: 0, output: output}} ->
          if String.match?(output, ~r/\[200\]|\[30[0-9]\]/) do
            {true, nil}
          else
            {false, "unexpected_status"}
          end

        {:ok, %{exit_code: code}} ->
          {false, "exit_code_#{code}"}

        {:error, :timeout} ->
          {false, "timeout"}

        {:error, reason} ->
          {false, "error_#{inspect(reason)}"}
      end

    elapsed = System.monotonic_time(:millisecond) - started_at
    response_time_ms = if is_up, do: elapsed, else: nil

    # Persist to heartbeat_checks + evaluate downtime
    Uptime.record_check(domain_id, %{
      is_up: is_up,
      checked_at: DateTime.utc_now(),
      response_time_ms: response_time_ms,
      error_reason: error_reason
    })

    # Keep backward compat: update domain_metadata
    Domains.upsert_domain_metadata(domain_id, %{
      is_up: is_up,
      last_heartbeat_at: DateTime.utc_now()
    })

    :ok
  end
end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: No errors.

- [ ] **Step 3: Run existing tests**

Run: `mix test`
Expected: All existing tests still pass (HeartbeatWorker has no dedicated tests — if any exist, they should pass).

- [ ] **Step 4: Commit**

```bash
git add lib/ravner/workers/heartbeat_worker.ex
git commit -m "feat(uptime): persist heartbeat checks and detect downtime in worker"
```

---


## Task 5: Heartbeat retention worker

**Files:**
- Create: `lib/ravner/workers/heartbeat_retention_worker.ex`
- Modify: `config/config.exs` (add to cron)

- [ ] **Step 1: Create retention worker**

```elixir
defmodule Ravner.Workers.HeartbeatRetentionWorker do
  @moduledoc """
  Prunes heartbeat_checks older than the configured retention period.
  Runs daily at 04:00 UTC.
  """
  use Oban.Worker, queue: :default

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Uptime.HeartbeatCheck

  # ponytail: retention days hardcoded; upgrade path: app config or admin setting
  @retention_days 90

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)

    {deleted, _} =
      HeartbeatCheck
      |> where([c], c.checked_at < ^cutoff)
      |> Repo.delete_all()

    if deleted > 0 do
      require Logger
      Logger.info("[HeartbeatRetention] Pruned #{deleted} checks older than #{@retention_days}d")
    end

    :ok
  end
end
```

- [ ] **Step 2: Add to Oban cron in config/config.exs**

Add this line inside the `crontab` list (after the LighthouseScanDispatcher entry):

```elixir
       {"0 4 * * *", Ravner.Workers.HeartbeatRetentionWorker}
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`

- [ ] **Step 4: Commit**

```bash
git add lib/ravner/workers/heartbeat_retention_worker.ex config/config.exs
git commit -m "feat(uptime): add daily retention worker to prune old heartbeat checks"
```

---


## Task 6: Status page LiveView — `/admin/uptime`

**Files:**
- Create: `lib/ravner_web/live/admin_live/uptime.ex`
- Create: `lib/ravner_web/live/admin_live/uptime.html.heex`
- Modify: `lib/ravner_web/router.ex`
- Modify: `lib/ravner_web/components/layouts/root.html.heex`

- [ ] **Step 1: Add route**

In `lib/ravner_web/router.ex`, inside the `:admin` live_session block (the one with `ensure_admin`), add:

```elixir
      live("/uptime", AdminLive.Uptime, :index)
      live("/uptime/report", AdminLive.UptimeReport, :index)
      live("/uptime/report/:domain_id", AdminLive.UptimeReport, :show)
```

- [ ] **Step 2: Add nav link**

In `lib/ravner_web/components/layouts/root.html.heex`, inside the admin-only top-right links section (after the "Jobs" link), add:

```heex
              <.link href={~p"/admin/uptime"} class="hover:text-neutral-500 transition-colors">
                Uptime
              </.link>
```

- [ ] **Step 3: Create the LiveView module**

Create `lib/ravner_web/live/admin_live/uptime.ex`:

```elixir
defmodule RavnerWeb.AdminLive.Uptime do
  use RavnerWeb, :live_view

  alias Ravner.Uptime

  @tick_interval 15_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_interval)

    {:ok, assign(socket, :page_title, "Uptime Monitor") |> load_data()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, load_data(socket)}
  end

  defp load_data(socket) do
    monitors = Uptime.list_monitored_domains()

    # Enrich with open downtime status
    enriched =
      Enum.map(monitors, fn meta ->
        open_window = Uptime.open_downtime(meta.domain_id)
        status = if open_window, do: :down, else: if(meta.is_up == false, do: :degraded, else: :up)

        %{
          domain: meta.domain,
          meta: meta,
          status: status,
          open_window: open_window
        }
      end)

    assign(socket, :monitors, enriched)
  end
end
```

- [ ] **Step 4: Create the template**

Create `lib/ravner_web/live/admin_live/uptime.html.heex`:

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <div class="max-w-5xl mx-auto px-6 py-8">
    <div class="flex items-center justify-between mb-8">
      <div>
        <h1 class="text-2xl font-light tracking-tight">Uptime Monitor</h1>
        <p class="text-sm font-light text-neutral-500 mt-1">
          Real-time status of all monitored domains.
        </p>
      </div>
      <.link
        navigate={~p"/admin/uptime/report"}
        class="px-4 py-2 text-xs font-medium border border-neutral-200 rounded-lg hover:bg-neutral-50 transition-colors dark:border-neutral-700 dark:hover:bg-neutral-800"
      >
        View Reports
      </.link>
    </div>

    <div class="grid grid-cols-3 gap-4 mb-8">
      <div class="card-line p-4">
        <p class="text-xs uppercase tracking-wide text-neutral-500 mb-1">Monitored</p>
        <p class="text-2xl font-light">{length(@monitors)}</p>
      </div>
      <div class="card-line p-4">
        <p class="text-xs uppercase tracking-wide text-neutral-500 mb-1">Up</p>
        <p class="text-2xl font-light text-green-600">
          {Enum.count(@monitors, &(&1.status == :up))}
        </p>
      </div>
      <div class="card-line p-4">
        <p class="text-xs uppercase tracking-wide text-neutral-500 mb-1">Down</p>
        <p class="text-2xl font-light text-red-600">
          {Enum.count(@monitors, &(&1.status == :down))}
        </p>
      </div>
    </div>

    <div class="card-line overflow-hidden">
      <table class="w-full text-sm">
        <thead class="bg-neutral-50 dark:bg-neutral-800 text-left text-xs uppercase tracking-wide text-neutral-500">
          <tr>
            <th class="px-4 py-3 font-normal">Status</th>
            <th class="px-4 py-3 font-normal">Domain</th>
            <th class="px-4 py-3 font-normal">Last Check</th>
            <th class="px-4 py-3 font-normal">Response</th>
            <th class="px-4 py-3 font-normal">Interval</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-neutral-100 dark:divide-neutral-800">
          <tr :for={m <- @monitors} class="hover:bg-neutral-50/50 dark:hover:bg-neutral-800/50">
            <td class="px-4 py-3">
              <%= cond do %>
                <% m.status == :up -> %>
                  <span class="inline-block w-2.5 h-2.5 rounded-full bg-green-500" title="Up"></span>
                <% m.status == :down -> %>
                  <span class="inline-block w-2.5 h-2.5 rounded-full bg-red-500" title="Down"></span>
                <% true -> %>
                  <span class="inline-block w-2.5 h-2.5 rounded-full bg-yellow-500" title="Degraded"></span>
              <% end %>
            </td>
            <td class="px-4 py-3 font-medium">
              <.link navigate={~p"/admin/uptime/report/#{m.domain.id}"} class="hover:underline">
                {m.domain.name}
              </.link>
            </td>
            <td class="px-4 py-3 text-neutral-500">
              <%= if m.meta.last_heartbeat_at do %>
                {Calendar.strftime(m.meta.last_heartbeat_at, "%H:%M:%S")}
              <% else %>
                —
              <% end %>
            </td>
            <td class="px-4 py-3 text-neutral-500">—</td>
            <td class="px-4 py-3">
              <span class="inline-flex px-1.5 py-0.5 text-[10px] uppercase tracking-wide rounded-sm font-medium bg-blue-50 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300">
                {m.meta.heartbeat_interval_minutes} min
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</Layouts.app>
```

- [ ] **Step 5: Verify compilation and visit page**

Run: `mix compile --warnings-as-errors`
Then start the server and visit `/admin/uptime` to confirm it renders.

- [ ] **Step 6: Commit**

```bash
git add lib/ravner_web/live/admin_live/uptime.ex lib/ravner_web/live/admin_live/uptime.html.heex lib/ravner_web/router.ex lib/ravner_web/components/layouts/root.html.heex
git commit -m "feat(uptime): add dedicated status page at /admin/uptime"
```

---


## Task 7: Uptime Report LiveView

**Files:**
- Create: `lib/ravner_web/live/admin_live/uptime_report.ex`
- Create: `lib/ravner_web/live/admin_live/uptime_report.html.heex`

- [ ] **Step 1: Create the LiveView**

Create `lib/ravner_web/live/admin_live/uptime_report.ex`:

```elixir
defmodule RavnerWeb.AdminLive.UptimeReport do
  use RavnerWeb, :live_view

  alias Ravner.Uptime
  alias Ravner.Domains

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Uptime Report")
      |> assign(:range, "7d")
      |> assign(:domain_id, params["domain_id"])
      |> load_report()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"domain_id" => domain_id}, _uri, socket) do
    {:noreply, socket |> assign(:domain_id, domain_id) |> load_report()}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:range, range) |> load_report()}
  end

  defp load_report(socket) do
    {from, to} = range_to_dates(socket.assigns.range)

    monitors = Uptime.list_monitored_domains()

    report =
      case socket.assigns.domain_id do
        nil ->
          Enum.map(monitors, fn meta ->
            %{
              domain: meta.domain,
              uptime_percent: Uptime.uptime_percent(meta.domain_id, from, to),
              windows: Uptime.downtime_windows(meta.domain_id, from, to)
            }
          end)

        domain_id ->
          domain_id = if is_binary(domain_id), do: String.to_integer(domain_id), else: domain_id
          domain = Domains.get_domain!(domain_id)
          windows = Uptime.downtime_windows(domain_id, from, to)
          checks = Uptime.recent_checks(domain_id, 120)

          [%{
            domain: domain,
            uptime_percent: Uptime.uptime_percent(domain_id, from, to),
            windows: windows,
            checks: checks
          }]
      end

    assign(socket, :report, report)
  end

  defp range_to_dates("24h"), do: {DateTime.add(DateTime.utc_now(), -1, :day), DateTime.utc_now()}
  defp range_to_dates("7d"), do: {DateTime.add(DateTime.utc_now(), -7, :day), DateTime.utc_now()}
  defp range_to_dates("30d"), do: {DateTime.add(DateTime.utc_now(), -30, :day), DateTime.utc_now()}
  defp range_to_dates(_), do: range_to_dates("7d")
end
```

- [ ] **Step 2: Create the template**

Create `lib/ravner_web/live/admin_live/uptime_report.html.heex`:

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <div class="max-w-5xl mx-auto px-6 py-8">
    <div class="flex items-center justify-between mb-8">
      <div>
        <h1 class="text-2xl font-light tracking-tight">Uptime Report</h1>
        <p class="text-sm font-light text-neutral-500 mt-1">
          Availability data for monitored domains.
        </p>
      </div>
      <div class="flex bg-neutral-100 p-1 rounded-lg dark:bg-neutral-800">
        <button
          :for={r <- ["24h", "7d", "30d"]}
          phx-click="set_range"
          phx-value-range={r}
          class={[
            "px-4 py-1.5 text-xs font-medium rounded-md transition-colors",
            @range == r && "bg-white text-neutral-900 shadow-sm dark:bg-neutral-700 dark:text-neutral-100",
            @range != r && "text-neutral-500 hover:text-neutral-700 dark:text-neutral-400"
          ]}
        >
          {r}
        </button>
      </div>
    </div>

    <div class="card-line overflow-hidden">
      <table class="w-full text-sm">
        <thead class="bg-neutral-50 dark:bg-neutral-800 text-left text-xs uppercase tracking-wide text-neutral-500">
          <tr>
            <th class="px-4 py-3 font-normal">Domain</th>
            <th class="px-4 py-3 font-normal">Uptime</th>
            <th class="px-4 py-3 font-normal">Incidents</th>
            <th class="px-4 py-3 font-normal">Total Downtime</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-neutral-100 dark:divide-neutral-800">
          <tr :for={row <- @report} class="hover:bg-neutral-50/50 dark:hover:bg-neutral-800/50">
            <td class="px-4 py-3 font-medium">
              <.link navigate={~p"/admin/uptime/report/#{row.domain.id}"} class="hover:underline">
                {row.domain.name}
              </.link>
            </td>
            <td class="px-4 py-3">
              <span class={[
                "font-medium",
                row.uptime_percent >= 99.9 && "text-green-600",
                row.uptime_percent >= 99.0 && row.uptime_percent < 99.9 && "text-yellow-600",
                row.uptime_percent < 99.0 && "text-red-600"
              ]}>
                {row.uptime_percent}%
              </span>
            </td>
            <td class="px-4 py-3 text-neutral-500">{length(row.windows)}</td>
            <td class="px-4 py-3 text-neutral-500">
              {format_duration(Enum.reduce(row.windows, 0, fn w, acc -> acc + (w.duration_seconds || 0) end))}
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <%!-- Downtime windows detail (shown when viewing single domain) --%>
    <%= if @domain_id && length(@report) == 1 do %>
      <% [detail] = @report %>
      <div class="mt-8">
        <h2 class="text-lg font-light mb-4">Downtime Windows</h2>
        <%= if detail.windows == [] do %>
          <p class="text-sm text-neutral-500">No downtime recorded in this period.</p>
        <% else %>
          <div class="card-line divide-y divide-neutral-100 dark:divide-neutral-800">
            <div :for={w <- detail.windows} class="px-4 py-3 flex items-center justify-between">
              <div>
                <span class="text-sm font-medium">
                  {Calendar.strftime(w.started_at, "%Y-%m-%d %H:%M")}
                </span>
                <span class="text-neutral-400 mx-2">→</span>
                <span class="text-sm">
                  <%= if w.ended_at do %>
                    {Calendar.strftime(w.ended_at, "%Y-%m-%d %H:%M")}
                  <% else %>
                    <span class="text-red-500 font-medium">ongoing</span>
                  <% end %>
                </span>
              </div>
              <span class="text-xs text-neutral-500">
                {format_duration(w.duration_seconds || DateTime.diff(DateTime.utc_now(), w.started_at, :second))}
              </span>
            </div>
          </div>
        <% end %>
      </div>
    <% end %>
  </div>
</Layouts.app>
```

Add a helper in the LiveView module:

```elixir
  # Add to uptime_report.ex
  defp format_duration(nil), do: "—"
  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`

- [ ] **Step 4: Commit**

```bash
git add lib/ravner_web/live/admin_live/uptime_report.ex lib/ravner_web/live/admin_live/uptime_report.html.heex
git commit -m "feat(uptime): add uptime report view with time range selector"
```

---


## Task 8: Notification tables migration

**Files:**
- Create: `priv/repo/migrations/YYYYMMDDHHMMSS_create_notification_tables.exs`

- [ ] **Step 1: Generate migration**

Run: `mix ecto.gen.migration create_notification_tables`

- [ ] **Step 2: Write the migration**

```elixir
defmodule Ravner.Repo.Migrations.CreateNotificationTables do
  use Ecto.Migration

  def change do
    # Global/group/per-domain notification policies
    create table(:uptime_notification_policies) do
      add :name, :string, null: false
      add :scope, :string, null: false  # "global", "group", "domain"
      add :domain_id, references(:domains, on_delete: :delete_all)
      add :enabled, :boolean, default: true, null: false
      add :still_down_interval_minutes, :integer, default: 30
      add :max_reminders, :integer, default: 5

      timestamps(type: :utc_datetime)
    end

    create index(:uptime_notification_policies, [:scope])
    create index(:uptime_notification_policies, [:domain_id])
    # Only one global policy
    create unique_index(:uptime_notification_policies, [:scope],
      where: "scope = 'global'", name: :uptime_notification_policies_global_unique)

    # Named notification groups
    create table(:uptime_notification_groups) do
      add :name, :string, null: false
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:uptime_notification_groups, [:name])

    # Join: policies <-> groups
    create table(:uptime_policy_groups, primary_key: false) do
      add :policy_id, references(:uptime_notification_policies, on_delete: :delete_all), null: false
      add :group_id, references(:uptime_notification_groups, on_delete: :delete_all), null: false
    end

    create unique_index(:uptime_policy_groups, [:policy_id, :group_id])

    # Recipients (belong to a group OR directly to a policy)
    create table(:uptime_notification_recipients) do
      add :policy_id, references(:uptime_notification_policies, on_delete: :delete_all)
      add :group_id, references(:uptime_notification_groups, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :delete_all)
      add :email, :string       # manual entry
      add :phone, :string       # manual entry
      add :channels, :string, null: false, default: "email"  # "email", "sms", "both"

      timestamps(type: :utc_datetime)
    end

    create index(:uptime_notification_recipients, [:policy_id])
    create index(:uptime_notification_recipients, [:group_id])

    # Delivery tracking (idempotency)
    create table(:uptime_notification_deliveries) do
      add :downtime_window_id, references(:downtime_windows, on_delete: :delete_all), null: false
      add :recipient_id, references(:uptime_notification_recipients, on_delete: :delete_all), null: false
      add :event_type, :string, null: false  # "incident_open", "incident_resolved", "still_down"
      add :sequence, :integer, default: 0    # for still_down reminders
      add :channel, :string, null: false     # "email" or "sms"
      add :delivered_at, :utc_datetime
      add :error, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:uptime_notification_deliveries,
      [:downtime_window_id, :recipient_id, :event_type, :sequence, :channel],
      name: :uptime_deliveries_idempotent_idx)
  end
end
```

- [ ] **Step 3: Run migration**

Run: `mix ecto.migrate`

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/*_create_notification_tables.exs
git commit -m "feat(uptime): add notification policy, group, recipient, delivery tables"
```

---


## Task 9: Notification schemas

**Files:**
- Create: `lib/ravner/uptime/notification_policy.ex`
- Create: `lib/ravner/uptime/notification_group.ex`
- Create: `lib/ravner/uptime/notification_recipient.ex`
- Create: `lib/ravner/uptime/notification_delivery.ex`

- [ ] **Step 1: NotificationPolicy schema**

```elixir
defmodule Ravner.Uptime.NotificationPolicy do
  use Ecto.Schema
  import Ecto.Changeset

  schema "uptime_notification_policies" do
    field :name, :string
    field :scope, :string  # "global", "group", "domain"
    field :enabled, :boolean, default: true
    field :still_down_interval_minutes, :integer, default: 30
    field :max_reminders, :integer, default: 5

    belongs_to :domain, Ravner.Domains.Domain
    has_many :recipients, Ravner.Uptime.NotificationRecipient
    many_to_many :groups, Ravner.Uptime.NotificationGroup,
      join_through: "uptime_policy_groups"

    timestamps(type: :utc_datetime)
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:name, :scope, :domain_id, :enabled, :still_down_interval_minutes, :max_reminders])
    |> validate_required([:name, :scope])
    |> validate_inclusion(:scope, ["global", "group", "domain"])
  end
end
```

- [ ] **Step 2: NotificationGroup schema**

```elixir
defmodule Ravner.Uptime.NotificationGroup do
  use Ecto.Schema
  import Ecto.Changeset

  schema "uptime_notification_groups" do
    field :name, :string
    field :description, :string

    has_many :recipients, Ravner.Uptime.NotificationRecipient
    many_to_many :policies, Ravner.Uptime.NotificationPolicy,
      join_through: "uptime_policy_groups"

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
```

- [ ] **Step 3: NotificationRecipient schema**

```elixir
defmodule Ravner.Uptime.NotificationRecipient do
  use Ecto.Schema
  import Ecto.Changeset

  schema "uptime_notification_recipients" do
    field :email, :string
    field :phone, :string
    field :channels, :string, default: "email"  # "email", "sms", "both"

    belongs_to :policy, Ravner.Uptime.NotificationPolicy
    belongs_to :group, Ravner.Uptime.NotificationGroup
    belongs_to :user, Ravner.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(recipient, attrs) do
    recipient
    |> cast(attrs, [:email, :phone, :channels, :policy_id, :group_id, :user_id])
    |> validate_required([:channels])
    |> validate_inclusion(:channels, ["email", "sms", "both"])
    |> validate_has_contact()
  end

  defp validate_has_contact(changeset) do
    user_id = get_field(changeset, :user_id)
    email = get_field(changeset, :email)
    phone = get_field(changeset, :phone)

    if is_nil(user_id) && is_nil(email) && is_nil(phone) do
      add_error(changeset, :email, "must provide a user, email, or phone")
    else
      changeset
    end
  end
end
```

- [ ] **Step 4: NotificationDelivery schema**

```elixir
defmodule Ravner.Uptime.NotificationDelivery do
  use Ecto.Schema

  schema "uptime_notification_deliveries" do
    field :event_type, :string
    field :sequence, :integer, default: 0
    field :channel, :string
    field :delivered_at, :utc_datetime
    field :error, :string

    belongs_to :downtime_window, Ravner.Uptime.DowntimeWindow
    belongs_to :recipient, Ravner.Uptime.NotificationRecipient

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
```

- [ ] **Step 5: Verify compilation**

Run: `mix compile --warnings-as-errors`

- [ ] **Step 6: Commit**

```bash
git add lib/ravner/uptime/notification_policy.ex lib/ravner/uptime/notification_group.ex lib/ravner/uptime/notification_recipient.ex lib/ravner/uptime/notification_delivery.ex
git commit -m "feat(uptime): add notification Ecto schemas"
```

---


## Task 10: SMS Adapter behaviour and implementations

**Files:**
- Create: `lib/ravner/uptime/sms_adapter.ex`
- Create: `lib/ravner/uptime/sms_adapters/log.ex`
- Create: `lib/ravner/uptime/sms_adapters/aws_sns.ex`
- Create: `lib/ravner/uptime/sms_adapters/twilio.ex`

- [ ] **Step 1: Define the behaviour**

Create `lib/ravner/uptime/sms_adapter.ex`:

```elixir
defmodule Ravner.Uptime.SmsAdapter do
  @moduledoc """
  Behaviour for SMS delivery adapters.
  """

  @callback send_sms(to :: String.t(), body :: String.t(), opts :: keyword()) ::
              {:ok, reference_id :: String.t()} | {:error, reason :: term()}

  @doc """
  Returns the currently configured adapter module.
  """
  def adapter do
    Application.get_env(:ravner, :uptime_sms_adapter, Ravner.Uptime.SmsAdapters.Log)
  end

  @doc """
  Sends an SMS using the configured adapter.
  """
  def send_sms(to, body, opts \\ []) do
    adapter().send_sms(to, body, opts)
  end
end
```

- [ ] **Step 2: Log adapter (dev/test)**

Create `lib/ravner/uptime/sms_adapters/log.ex`:

```elixir
defmodule Ravner.Uptime.SmsAdapters.Log do
  @moduledoc "Dev/test SMS adapter — logs to console."
  @behaviour Ravner.Uptime.SmsAdapter

  require Logger

  @impl true
  def send_sms(to, body, _opts) do
    Logger.info("[SMS:Log] To: #{to} | Body: #{body}")
    {:ok, "log_#{System.unique_integer([:positive])}"}
  end
end
```

- [ ] **Step 3: AWS SNS adapter**

Create `lib/ravner/uptime/sms_adapters/aws_sns.ex`:

```elixir
defmodule Ravner.Uptime.SmsAdapters.AwsSns do
  @moduledoc """
  SMS delivery via AWS SNS using Req + AWS Signature V4.
  Credentials from env: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION.
  """
  @behaviour Ravner.Uptime.SmsAdapter

  require Logger

  @impl true
  def send_sms(to, body, opts) do
    region = Keyword.get(opts, :region, System.get_env("AWS_REGION", "eu-central-1"))
    sender_id = Keyword.get(opts, :sender_id, "Ravner")

    params = %{
      "Action" => "Publish",
      "Version" => "2010-03-31",
      "PhoneNumber" => to,
      "Message" => body,
      "MessageAttributes.entry.1.Name" => "AWS.SNS.SMS.SenderID",
      "MessageAttributes.entry.1.Value.DataType" => "String",
      "MessageAttributes.entry.1.Value.StringValue" => sender_id
    }

    url = "https://sns.#{region}.amazonaws.com/"

    # ponytail: uses Req with manual signing; upgrade path: ex_aws_sns dep
    case sign_and_post(url, params, region) do
      {:ok, %{status: 200, body: resp_body}} ->
        # Extract MessageId from XML response
        case Regex.run(~r/<MessageId>(.+?)<\/MessageId>/, resp_body) do
          [_, message_id] -> {:ok, message_id}
          _ -> {:ok, "sns_ok"}
        end

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("[SMS:AwsSns] HTTP #{status}: #{resp_body}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("[SMS:AwsSns] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp sign_and_post(url, params, region) do
    # AWS Signature V4 for SNS
    access_key = System.get_env("AWS_ACCESS_KEY_ID")
    secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")

    if is_nil(access_key) || is_nil(secret_key) do
      {:error, :missing_aws_credentials}
    else
      body = URI.encode_query(params)
      now = DateTime.utc_now()
      date = Calendar.strftime(now, "%Y%m%d")
      datetime = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")

      headers = [
        {"content-type", "application/x-www-form-urlencoded"},
        {"host", "sns.#{region}.amazonaws.com"},
        {"x-amz-date", datetime}
      ]

      # Canonical request
      signed_headers = "content-type;host;x-amz-date"
      payload_hash = sha256_hex(body)

      canonical =
        Enum.join([
          "POST", "/", "", 
          "content-type:application/x-www-form-urlencoded",
          "host:sns.#{region}.amazonaws.com",
          "x-amz-date:#{datetime}",
          "", signed_headers, payload_hash
        ], "\n")

      # String to sign
      scope = "#{date}/#{region}/sns/aws4_request"
      string_to_sign = "AWS4-HMAC-SHA256\n#{datetime}\n#{scope}\n#{sha256_hex(canonical)}"

      # Signing key
      k_date = hmac("AWS4#{secret_key}", date)
      k_region = hmac(k_date, region)
      k_service = hmac(k_region, "sns")
      k_signing = hmac(k_service, "aws4_request")

      signature = hmac_hex(k_signing, string_to_sign)

      auth = "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
      headers = [{"authorization", auth} | headers]

      Req.post(url, body: body, headers: headers)
    end
  end

  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hmac_hex(key, data), do: hmac(key, data) |> Base.encode16(case: :lower)
end
```

- [ ] **Step 4: Twilio adapter**

Create `lib/ravner/uptime/sms_adapters/twilio.ex`:

```elixir
defmodule Ravner.Uptime.SmsAdapters.Twilio do
  @moduledoc """
  SMS delivery via Twilio REST API.
  Credentials from env: TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER.
  """
  @behaviour Ravner.Uptime.SmsAdapter

  require Logger

  @impl true
  def send_sms(to, body, _opts) do
    account_sid = System.get_env("TWILIO_ACCOUNT_SID")
    auth_token = System.get_env("TWILIO_AUTH_TOKEN")
    from = System.get_env("TWILIO_FROM_NUMBER")

    if is_nil(account_sid) || is_nil(auth_token) || is_nil(from) do
      {:error, :missing_twilio_credentials}
    else
      url = "https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Messages.json"

      case Req.post(url,
             form: [{"To", to}, {"From", from}, {"Body", body}],
             auth: {:basic, "#{account_sid}:#{auth_token}"}
           ) do
        {:ok, %{status: 201, body: %{"sid" => sid}}} ->
          {:ok, sid}

        {:ok, %{status: status, body: resp}} ->
          Logger.error("[SMS:Twilio] HTTP #{status}: #{inspect(resp)}")
          {:error, {:http_error, status}}

        {:error, reason} ->
          Logger.error("[SMS:Twilio] Request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end
```

- [ ] **Step 5: Add config**

In `config/config.exs`, add after the Oban config block:

```elixir
# Uptime monitoring
config :ravner, :uptime_sms_adapter, Ravner.Uptime.SmsAdapters.Log
```

And in `config/runtime.exs`, add for production:

```elixir
    # SMS adapter (production)
    sms_adapter =
      case System.get_env("UPTIME_SMS_ADAPTER", "log") do
        "aws_sns" -> Ravner.Uptime.SmsAdapters.AwsSns
        "twilio" -> Ravner.Uptime.SmsAdapters.Twilio
        _ -> Ravner.Uptime.SmsAdapters.Log
      end

    config :ravner, :uptime_sms_adapter, sms_adapter
```

- [ ] **Step 6: Verify compilation**

Run: `mix compile --warnings-as-errors`

- [ ] **Step 7: Commit**

```bash
git add lib/ravner/uptime/sms_adapter.ex lib/ravner/uptime/sms_adapters/ config/config.exs config/runtime.exs
git commit -m "feat(uptime): add SMS adapter behaviour with Log, AwsSns, Twilio implementations"
```

---


## Task 11: Uptime Notifier (email templates) and Notification dispatch

**Files:**
- Create: `lib/ravner/uptime/uptime_notifier.ex`
- Create: `lib/ravner/uptime/notifications.ex`
- Create: `lib/ravner/workers/uptime_notification_worker.ex`

- [ ] **Step 1: Email templates**

Create `lib/ravner/uptime/uptime_notifier.ex`:

```elixir
defmodule Ravner.Uptime.UptimeNotifier do
  @moduledoc """
  Builds and delivers uptime notification emails.
  """
  import Swoosh.Email
  alias Ravner.Mailer

  defp sender do
    from_email = Application.get_env(:ravner, :uptime_mail_from,
      Application.get_env(:ravner, :mail_from, "noreply@example.com"))
    from_name = Application.get_env(:ravner, :uptime_mail_from_name, "Ravner Uptime")
    {from_name, from_email}
  end

  def deliver_incident_open(to_email, domain_name, started_at) do
    new()
    |> to(to_email)
    |> from(sender())
    |> subject("[DOWN] #{domain_name} is unreachable")
    |> text_body("""
    INCIDENT OPEN

    Domain: #{domain_name}
    Status: DOWN
    Since:  #{Calendar.strftime(started_at, "%Y-%m-%d %H:%M UTC")}

    We detected multiple consecutive failures. Monitoring will continue
    and you'll be notified when the domain recovers.

    — Ravner Uptime Monitor
    """)
    |> Mailer.deliver()
  end

  def deliver_incident_resolved(to_email, domain_name, started_at, ended_at, duration_seconds) do
    new()
    |> to(to_email)
    |> from(sender())
    |> subject("[RECOVERED] #{domain_name} is back up")
    |> text_body("""
    INCIDENT RESOLVED

    Domain:   #{domain_name}
    Status:   UP (recovered)
    Down:     #{Calendar.strftime(started_at, "%Y-%m-%d %H:%M UTC")}
    Resolved: #{Calendar.strftime(ended_at, "%Y-%m-%d %H:%M UTC")}
    Duration: #{format_duration(duration_seconds)}

    — Ravner Uptime Monitor
    """)
    |> Mailer.deliver()
  end

  def deliver_still_down(to_email, domain_name, started_at, reminder_number) do
    new()
    |> to(to_email)
    |> from(sender())
    |> subject("[STILL DOWN] #{domain_name} — reminder ##{reminder_number}")
    |> text_body("""
    STILL DOWN (Reminder ##{reminder_number})

    Domain: #{domain_name}
    Status: DOWN
    Since:  #{Calendar.strftime(started_at, "%Y-%m-%d %H:%M UTC")}

    The domain has not recovered yet.

    — Ravner Uptime Monitor
    """)
    |> Mailer.deliver()
  end

  defp format_duration(nil), do: "unknown"
  defp format_duration(s) when s < 60, do: "#{s} seconds"
  defp format_duration(s) when s < 3600, do: "#{div(s, 60)} minutes"
  defp format_duration(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
end
```

- [ ] **Step 2: Notification dispatch logic**

Create `lib/ravner/uptime/notifications.ex`:

```elixir
defmodule Ravner.Uptime.Notifications do
  @moduledoc """
  Resolves notification policies and dispatches alerts for uptime events.
  """

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Uptime.{NotificationPolicy, NotificationRecipient, NotificationDelivery, DowntimeWindow}
  alias Ravner.Uptime.{UptimeNotifier, SmsAdapter}

  @doc """
  Dispatches notifications for an event (:incident_open, :incident_resolved).
  Enqueues an Oban worker for async delivery.
  """
  def dispatch(event, %DowntimeWindow{} = window) do
    %{event: to_string(event), downtime_window_id: window.id, domain_id: window.domain_id}
    |> Ravner.Workers.UptimeNotificationWorker.new()
    |> Oban.insert()
  end

  @doc """
  Resolves recipients for a domain based on policy precedence:
  per-domain > group > global.
  """
  def resolve_recipients(domain_id) do
    # 1. Per-domain policy
    case get_policy("domain", domain_id) do
      %NotificationPolicy{} = policy ->
        recipients_for_policy(policy)

      nil ->
        # 2. Group policies linked to domain (via domain's groups)
        # ponytail: simplified — groups attach to policies, not domains directly.
        # For MVP, fall through to global if no domain policy exists.
        # Upgrade path: add domain_group_memberships join table.
        case get_policy("global", nil) do
          %NotificationPolicy{} = policy -> recipients_for_policy(policy)
          nil -> []
        end
    end
  end

  defp get_policy(scope, domain_id) do
    query =
      NotificationPolicy
      |> where(scope: ^scope)
      |> where(enabled: true)

    query =
      if domain_id do
        where(query, domain_id: ^domain_id)
      else
        query
      end

    Repo.one(query |> limit(1))
  end

  defp recipients_for_policy(policy) do
    # Direct recipients on the policy
    direct =
      NotificationRecipient
      |> where(policy_id: ^policy.id)
      |> Repo.all()
      |> Repo.preload(:user)

    # Recipients from associated groups
    group_ids =
      from(pg in "uptime_policy_groups",
        where: pg.policy_id == ^policy.id,
        select: pg.group_id
      )
      |> Repo.all()

    group_recipients =
      if group_ids != [] do
        NotificationRecipient
        |> where([r], r.group_id in ^group_ids)
        |> Repo.all()
        |> Repo.preload(:user)
      else
        []
      end

    Enum.uniq_by(direct ++ group_recipients, & &1.id)
  end

  @doc """
  Delivers a notification to a single recipient for an event.
  Checks idempotency before sending.
  """
  def deliver_to_recipient(recipient, event, window, opts \\ []) do
    sequence = Keyword.get(opts, :sequence, 0)
    domain_name = Keyword.get(opts, :domain_name, "unknown")

    channels = expand_channels(recipient)
    email = resolve_email(recipient)
    phone = resolve_phone(recipient)

    for channel <- channels do
      unless already_delivered?(window.id, recipient.id, event, sequence, channel) do
        result = send_via_channel(channel, email, phone, event, window, domain_name, sequence)

        %NotificationDelivery{
          downtime_window_id: window.id,
          recipient_id: recipient.id,
          event_type: to_string(event),
          sequence: sequence,
          channel: channel,
          delivered_at: if(match?({:ok, _}, result), do: DateTime.utc_now(:second)),
          error: if(match?({:error, reason}, result), do: inspect(elem(result, 1)))
        }
        |> Repo.insert!(on_conflict: :nothing)
      end
    end
  end

  defp expand_channels(%{channels: "both"}), do: ["email", "sms"]
  defp expand_channels(%{channels: ch}), do: [ch]

  defp resolve_email(%{user: %{email: email}}) when is_binary(email), do: email
  defp resolve_email(%{email: email}) when is_binary(email), do: email
  defp resolve_email(_), do: nil

  defp resolve_phone(%{phone: phone}) when is_binary(phone), do: phone
  defp resolve_phone(_), do: nil

  defp send_via_channel("email", email, _phone, event, window, domain_name, sequence) do
    if email do
      case event do
        "incident_open" ->
          UptimeNotifier.deliver_incident_open(email, domain_name, window.started_at)
        "incident_resolved" ->
          UptimeNotifier.deliver_incident_resolved(email, domain_name, window.started_at, window.ended_at, window.duration_seconds)
        "still_down" ->
          UptimeNotifier.deliver_still_down(email, domain_name, window.started_at, sequence)
      end
    else
      {:error, :no_email}
    end
  end

  defp send_via_channel("sms", _email, phone, event, window, domain_name, _sequence) do
    if phone do
      body =
        case event do
          "incident_open" -> "[DOWN] #{domain_name} is unreachable since #{Calendar.strftime(window.started_at, "%H:%M UTC")}"
          "incident_resolved" -> "[UP] #{domain_name} recovered at #{Calendar.strftime(window.ended_at, "%H:%M UTC")}"
          "still_down" -> "[STILL DOWN] #{domain_name} since #{Calendar.strftime(window.started_at, "%H:%M UTC")}"
        end

      SmsAdapter.send_sms(phone, body)
    else
      {:error, :no_phone}
    end
  end

  defp already_delivered?(window_id, recipient_id, event, sequence, channel) do
    NotificationDelivery
    |> where(downtime_window_id: ^window_id)
    |> where(recipient_id: ^recipient_id)
    |> where(event_type: ^to_string(event))
    |> where(sequence: ^sequence)
    |> where(channel: ^channel)
    |> where([d], not is_nil(d.delivered_at))
    |> Repo.exists?()
  end
end
```

- [ ] **Step 3: Notification Oban worker**

Create `lib/ravner/workers/uptime_notification_worker.ex`:

```elixir
defmodule Ravner.Workers.UptimeNotificationWorker do
  @moduledoc """
  Oban worker that delivers uptime notifications for a downtime event.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ravner.Repo
  alias Ravner.Uptime.{Notifications, DowntimeWindow}
  alias Ravner.Domains

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event" => event, "downtime_window_id" => window_id, "domain_id" => domain_id}}) do
    window = Repo.get!(DowntimeWindow, window_id)
    domain = Domains.get_domain!(domain_id)
    recipients = Notifications.resolve_recipients(domain_id)

    for recipient <- recipients do
      Notifications.deliver_to_recipient(recipient, event, window, domain_name: domain.name)
    end

    :ok
  end
end
```

- [ ] **Step 4: Wire notifications into downtime detection**

In `lib/ravner/uptime.ex`, modify `evaluate_downtime` to dispatch notifications:

After opening a new downtime window:
```elixir
        window =
          %DowntimeWindow{...}
          |> Repo.insert!()

        Ravner.Uptime.Notifications.dispatch("incident_open", window)
```

In `close_open_window`, after the update_all, if rows were affected:
```elixir
  defp close_open_window(domain_id) do
    now = DateTime.utc_now(:second)

    {updated, _} =
      from(w in DowntimeWindow,
        where: w.domain_id == ^domain_id,
        where: is_nil(w.ended_at),
        update: [set: [
          ended_at: ^now,
          duration_seconds: fragment("EXTRACT(EPOCH FROM ? - started_at)::integer", ^now)
        ]]
      )
      |> Repo.update_all([])

    if updated > 0 do
      # Fetch the just-closed window to dispatch notification
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
```

- [ ] **Step 5: Add uptime mailer config**

In `config/config.exs`:
```elixir
config :ravner, :uptime_mail_from, "uptime@example.com"
config :ravner, :uptime_mail_from_name, "Ravner Uptime"
```

In `config/runtime.exs` (production section):
```elixir
    config :ravner, :uptime_mail_from, System.get_env("UPTIME_MAIL_FROM", mail_from)
    config :ravner, :uptime_mail_from_name, System.get_env("UPTIME_MAIL_FROM_NAME", "Ravner Uptime")
```

- [ ] **Step 6: Verify compilation**

Run: `mix compile --warnings-as-errors`

- [ ] **Step 7: Commit**

```bash
git add lib/ravner/uptime/uptime_notifier.ex lib/ravner/uptime/notifications.ex lib/ravner/workers/uptime_notification_worker.ex lib/ravner/uptime.ex config/config.exs config/runtime.exs
git commit -m "feat(uptime): add notification dispatch with email/SMS delivery and idempotency"
```

---


## Task 12: Downtime notes

**Files:**
- Create: `priv/repo/migrations/YYYYMMDDHHMMSS_create_downtime_notes.exs`
- Create: `lib/ravner/uptime/downtime_note.ex`
- Modify: `lib/ravner/uptime.ex` (add CRUD for notes)

- [ ] **Step 1: Generate migration**

Run: `mix ecto.gen.migration create_downtime_notes`

- [ ] **Step 2: Write migration**

```elixir
defmodule Ravner.Repo.Migrations.CreateDowntimeNotes do
  use Ecto.Migration

  def change do
    create table(:downtime_notes) do
      add :downtime_window_id, references(:downtime_windows, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :nilify_all)
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:downtime_notes, [:downtime_window_id])
  end
end
```

- [ ] **Step 3: Schema**

Create `lib/ravner/uptime/downtime_note.ex`:

```elixir
defmodule Ravner.Uptime.DowntimeNote do
  use Ecto.Schema
  import Ecto.Changeset

  schema "downtime_notes" do
    field :content, :string

    belongs_to :downtime_window, Ravner.Uptime.DowntimeWindow
    belongs_to :author, Ravner.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:content, :downtime_window_id, :author_id])
    |> validate_required([:content, :downtime_window_id])
  end
end
```

- [ ] **Step 4: Add CRUD functions to Uptime context**

Add to `lib/ravner/uptime.ex`:

```elixir
  alias Ravner.Uptime.DowntimeNote

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
```

- [ ] **Step 5: Run migration and verify**

Run: `mix ecto.migrate && mix compile --warnings-as-errors`

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations/*_create_downtime_notes.exs lib/ravner/uptime/downtime_note.ex lib/ravner/uptime.ex
git commit -m "feat(uptime): add downtime governance notes"
```

---


## Task 13: Notification management admin UI

**Files:**
- Create: `lib/ravner_web/live/admin_live/uptime_notifications.ex`
- Create: `lib/ravner_web/live/admin_live/uptime_notifications.html.heex`
- Modify: `lib/ravner_web/router.ex`

This task creates the admin UI for managing notification policies, groups, and recipients. It also includes SMS provider selection.

- [ ] **Step 1: Add routes**

In `lib/ravner_web/router.ex`, in the `:admin` live_session:

```elixir
      live("/uptime/notifications", AdminLive.UptimeNotifications, :index)
```

- [ ] **Step 2: Create LiveView**

Create `lib/ravner_web/live/admin_live/uptime_notifications.ex`:

```elixir
defmodule RavnerWeb.AdminLive.UptimeNotifications do
  use RavnerWeb, :live_view

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Uptime.{NotificationPolicy, NotificationGroup, NotificationRecipient}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Uptime Notifications")
     |> assign(:active_tab, :policies)
     |> load_data()}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("create_global_policy", _params, socket) do
    case Repo.insert(%NotificationPolicy{name: "Global Policy", scope: "global", enabled: true},
           on_conflict: :nothing) do
      {:ok, _} -> {:noreply, load_data(socket) |> put_flash(:info, "Global policy created.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed.")}
    end
  end

  @impl true
  def handle_event("create_group", %{"name" => name}, socket) do
    case %NotificationGroup{} |> NotificationGroup.changeset(%{name: name}) |> Repo.insert() do
      {:ok, _} -> {:noreply, load_data(socket) |> put_flash(:info, "Group created.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed — name may already exist.")}
    end
  end

  @impl true
  def handle_event("add_recipient", params, socket) do
    attrs = %{
      policy_id: parse_id(params["policy_id"]),
      group_id: parse_id(params["group_id"]),
      user_id: parse_id(params["user_id"]),
      email: blank_to_nil(params["email"]),
      phone: blank_to_nil(params["phone"]),
      channels: params["channels"] || "email"
    }

    case %NotificationRecipient{} |> NotificationRecipient.changeset(attrs) |> Repo.insert() do
      {:ok, _} -> {:noreply, load_data(socket) |> put_flash(:info, "Recipient added.")}
      {:error, cs} -> {:noreply, put_flash(socket, :error, "Failed: #{inspect(cs.errors)}")}
    end
  end

  @impl true
  def handle_event("delete_recipient", %{"id" => id}, socket) do
    Repo.get!(NotificationRecipient, id) |> Repo.delete!()
    {:noreply, load_data(socket) |> put_flash(:info, "Removed.")}
  end

  defp load_data(socket) do
    policies = NotificationPolicy |> order_by(asc: :scope) |> Repo.all() |> Repo.preload([:recipients, :domain])
    groups = NotificationGroup |> order_by(asc: :name) |> Repo.all() |> Repo.preload(:recipients)
    users = Ravner.Accounts.User |> where(active: true) |> order_by(asc: :name) |> Repo.all()

    # Current SMS adapter
    sms_adapter = Application.get_env(:ravner, :uptime_sms_adapter) |> Module.split() |> List.last()

    socket
    |> assign(:policies, policies)
    |> assign(:groups, groups)
    |> assign(:users, users)
    |> assign(:sms_adapter, sms_adapter)
  end

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil
  defp parse_id(s) when is_binary(s), do: String.to_integer(s)
  defp parse_id(i), do: i

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s
end
```

- [ ] **Step 3: Create template**

Create `lib/ravner_web/live/admin_live/uptime_notifications.html.heex` with tabs for Policies, Groups, and SMS Provider settings. (Template follows the same card-line/table pattern as jobs.html.heex — render policies with their recipients, groups with members, and a simple display of the active SMS adapter with a note that it's configured via environment variable.)

- [ ] **Step 4: Verify compilation**

Run: `mix compile --warnings-as-errors`

- [ ] **Step 5: Commit**

```bash
git add lib/ravner_web/live/admin_live/uptime_notifications.ex lib/ravner_web/live/admin_live/uptime_notifications.html.heex lib/ravner_web/router.ex
git commit -m "feat(uptime): add notification management admin UI"
```

---


## Task 14: Integrate notes into report detail view

**Files:**
- Modify: `lib/ravner_web/live/admin_live/uptime_report.ex`
- Modify: `lib/ravner_web/live/admin_live/uptime_report.html.heex`

- [ ] **Step 1: Add note handling to LiveView**

In `uptime_report.ex`, add assigns and event handlers:

```elixir
  # In mount, add:
  |> assign(:note_form, to_form(%{"content" => ""}, as: :note))

  # Add handle_event for creating notes:
  @impl true
  def handle_event("add_note", %{"note" => %{"content" => content}, "window_id" => window_id}, socket) do
    user = socket.assigns.current_scope.user

    case Ravner.Uptime.create_note(%{
      content: content,
      downtime_window_id: String.to_integer(window_id),
      author_id: user.id
    }) do
      {:ok, _} ->
        {:noreply, socket |> load_report() |> assign(:note_form, to_form(%{"content" => ""}, as: :note))}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add note.")}
    end
  end
```

Also preload notes in `load_report` when showing single domain detail:
```elixir
  # In the single-domain branch of load_report, after fetching windows:
  windows = Enum.map(windows, fn w ->
    Map.put(w, :notes, Ravner.Uptime.list_notes(w.id))
  end)
```

- [ ] **Step 2: Add notes UI to template**

In the downtime windows detail section of `uptime_report.html.heex`, after each window's duration display, add:

```heex
              <%!-- Notes for this window --%>
              <%= if Map.get(w, :notes, []) != [] do %>
                <div class="mt-2 pl-4 border-l-2 border-neutral-200 dark:border-neutral-700">
                  <div :for={note <- w.notes} class="mb-2">
                    <p class="text-xs text-neutral-400">
                      {note.author && note.author.name || "System"} — {Calendar.strftime(note.inserted_at, "%Y-%m-%d %H:%M")}
                    </p>
                    <p class="text-sm">{note.content}</p>
                  </div>
                </div>
              <% end %>

              <%!-- Add note form (editor/admin only) --%>
              <%= if @current_scope.user.role in [:admin, :editor] do %>
                <.form
                  for={@note_form}
                  id={"note-form-#{w.id}"}
                  phx-submit="add_note"
                  phx-value-window_id={w.id}
                  class="mt-2 flex gap-2"
                >
                  <.input field={@note_form[:content]} type="text" placeholder="Add governance note..." class="flex-1 text-sm" />
                  <button type="submit" class="px-3 py-1 text-xs border border-neutral-200 rounded hover:bg-neutral-50 dark:border-neutral-700 dark:hover:bg-neutral-800">
                    Add
                  </button>
                </.form>
              <% end %>
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`

- [ ] **Step 4: Commit**

```bash
git add lib/ravner_web/live/admin_live/uptime_report.ex lib/ravner_web/live/admin_live/uptime_report.html.heex
git commit -m "feat(uptime): add governance notes to report detail view"
```

---


## Task 15: Final verification and precommit

**Files:**
- All files from Tasks 1–14

- [ ] **Step 1: Run full precommit**

Run: `mix precommit`

This runs: `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`

Expected: All pass. Fix any warnings/failures before proceeding.

- [ ] **Step 2: Fix any test failures**

If tests fail, examine failures and fix. Common issues:
- Missing aliases in test helpers
- Domain factory/fixture differences
- Missing preloads

- [ ] **Step 3: Manual smoke test**

Start the server (`mix phx.server`), log in as admin, verify:
- `/admin/uptime` shows monitored domains
- `/admin/uptime/report` shows report with time range selector
- `/admin/uptime/notifications` shows notification management UI
- Uptime nav link appears in header

- [ ] **Step 4: Final commit (if fixes needed)**

```bash
git add -A
git commit -m "fix(uptime): address precommit findings"
```

---

## Notes for implementer

1. **Test domain fixture**: Check `test/support/` for existing domain creation helpers. The test in Task 3 uses a naive `insert_domain/1` — adapt to whatever factory exists.

2. **`card-line` CSS class**: Already defined in the project's app.css — used across all admin views for bordered cards.

3. **Existing `format_duration`**: If a shared helper already exists elsewhere in the codebase, use that instead of defining new ones in each LiveView.

4. **SMS in production**: The AwsSns adapter uses raw Req + SigV4 signing to avoid adding `ex_aws` as a dependency. If `ex_aws` is later added for other reasons, refactor to use `ExAws.SNS.publish/2`.

5. **Group-to-domain mapping**: The MVP notification resolution skips the "group" level (falls through from per-domain to global). To fully implement group-level policies, a join table `uptime_monitor_groups` (domain_id, group_id) is needed — this is noted as upgrade path in the code.

6. **Still-down reminders**: Not wired in this plan's scope. The schema supports it (sequence field on deliveries, interval on policy). Implementation: a periodic Oban worker that checks open windows older than `still_down_interval_minutes` and delivers with incrementing sequence up to `max_reminders`.
