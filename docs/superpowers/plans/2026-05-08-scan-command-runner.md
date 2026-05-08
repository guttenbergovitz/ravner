# Scan Command Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Centralize scanner CLI execution, route quick scans through a stable context boundary, and make bulk scan concurrency configurable.

**Architecture:** Add `Ravner.SystemCommand` as the only low-level Port runner, preserving process-group cleanup from `Ravner.Scans.SecurityRunner`. Add `Ravner.Scans.run_quick_scan/1` and `Ravner.Scans.scan_max_concurrency/0` so LiveViews no longer know the scan pipeline or hard-code concurrency.

**Tech Stack:** Elixir, Phoenix LiveView, OTP Ports, `Task.Supervisor`, `Task.async_stream`, ExUnit.

---

## File Structure

- Create `lib/ravner/system_command.ex`: command lookup, process-group spawning, output collection, timeout cleanup.
- Create `test/ravner/system_command_test.exs`: focused tests for command success, missing executable, and timeout.
- Modify `lib/ravner/scans.ex`: use `Ravner.SystemCommand`, add `run_quick_scan/1`, add `scan_max_concurrency/0`, remove local simple timeout helper.
- Modify `lib/ravner/scans/security_runner.ex`: use `Ravner.SystemCommand`, remove local process-group timeout helper.
- Modify `lib/ravner_web/live/admin_live/settings.ex`: use `Ravner.SystemCommand`, remove local timeout helper.
- Modify `lib/ravner_web/live/domain_live/index.ex`: call `Scans.run_quick_scan/1` and `Scans.scan_max_concurrency/0`.
- Modify `config/config.exs`: default `scan_max_concurrency`.
- Modify `config/runtime.exs`: runtime override from `SCAN_MAX_CONCURRENCY`.
- Create or modify tests in `test/ravner/scans_test.exs`: config helper behavior for `scan_max_concurrency/0`.

---

### Task 1: Add Shared Command Runner

**Files:**
- Create: `lib/ravner/system_command.ex`
- Test: `test/ravner/system_command_test.exs`

- [ ] **Step 1: Write failing tests for command execution**

Create `test/ravner/system_command_test.exs`:

```elixir
defmodule Ravner.SystemCommandTest do
  use ExUnit.Case, async: true

  alias Ravner.SystemCommand

  test "run_with_timeout returns output and exit status for a successful command" do
    assert {output, 0} =
             SystemCommand.run_with_timeout(
               "elixir",
               ["-e", "IO.write(\"ok\")"],
               5_000
             )

    assert output == "ok"
  end

  test "run_with_timeout returns exit status for a failing command" do
    assert {_output, 7} =
             SystemCommand.run_with_timeout(
               "elixir",
               ["-e", "System.halt(7)"],
               5_000
             )
  end

  test "run_with_timeout returns an explicit error for a missing executable" do
    assert {:error, "definitely-not-ravner-command executable not found"} =
             SystemCommand.run_with_timeout(
               "definitely-not-ravner-command",
               [],
               5_000
             )
  end

  test "run_with_timeout returns timeout for a long running command" do
    assert {:error, :timeout} =
             SystemCommand.run_with_timeout(
               "elixir",
               ["-e", "Process.sleep(:infinity)"],
               50
             )
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
mix test test/ravner/system_command_test.exs
```

Expected: compilation fails because `Ravner.SystemCommand` is not defined.

- [ ] **Step 3: Implement `Ravner.SystemCommand`**

Create `lib/ravner/system_command.ex`:

```elixir
defmodule Ravner.SystemCommand do
  @moduledoc """
  Runs external commands with timeout and process-group cleanup.
  """

  @type result :: {String.t(), non_neg_integer()} | {:error, :timeout} | {:error, String.t()}

  @spec run_with_timeout(String.t(), [String.t()], non_neg_integer(), keyword()) :: result()
  def run_with_timeout(command, args, timeout, opts \\ [])
      when is_binary(command) and is_list(args) and is_integer(timeout) and timeout >= 0 do
    stdin = Keyword.get(opts, :stdin, :dev_null)

    with {:ok, executable} <- find_executable(command),
         {:ok, perl_path} <- find_perl() do
      shell_cmd = build_shell_command(executable, args, stdin)
      perl_script = "use POSIX qw(setsid); setsid(); exec @ARGV"

      port =
        Port.open(
          {:spawn_executable, perl_path},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["-e", perl_script, "--", "/bin/bash", "-c", shell_cmd]
          ]
        )

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      deadline = System.monotonic_time(:millisecond) + timeout

      case collect_port_output(port, deadline, "") do
        {:ok, output, status} ->
          {output, status}

        :timeout ->
          if os_pid, do: kill_process_group(os_pid)
          close_port(port)
          {:error, :timeout}
      end
    end
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> {:error, "#{command} executable not found"}
      executable -> {:ok, executable}
    end
  end

  defp find_perl do
    case System.find_executable("perl") do
      nil -> {:error, "perl executable not found"}
      perl_path -> {:ok, perl_path}
    end
  end

  defp build_shell_command(executable, args, :dev_null) do
    "exec #{escape_args([executable | args])} </dev/null"
  end

  defp build_shell_command(executable, args, :inherit) do
    "exec #{escape_args([executable | args])}"
  end

  defp collect_port_output(port, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, deadline, acc <> data)

      {^port, {:exit_status, status}} ->
        {:ok, acc, status}
    after
      remaining ->
        :timeout
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp kill_process_group(os_pid) do
    System.cmd("kill", ["-TERM", "-#{os_pid}"], stderr_to_stdout: true)
    Process.sleep(100)
    System.cmd("kill", ["-KILL", "-#{os_pid}"], stderr_to_stdout: true)
    :ok
  end

  defp escape_args(args) do
    args
    |> Enum.map(&shell_escape/1)
    |> Enum.join(" ")
  end

  defp shell_escape(arg) do
    "'" <> String.replace(to_string(arg), "'", "'\"'\"'") <> "'"
  end
end
```

- [ ] **Step 4: Run command runner tests**

Run:

```bash
mix test test/ravner/system_command_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/ravner/system_command.ex test/ravner/system_command_test.exs
git commit -m "feat(scans): add shared system command runner"
```

---

### Task 2: Replace Local Timeout Runners

**Files:**
- Modify: `lib/ravner/scans.ex`
- Modify: `lib/ravner/scans/security_runner.ex`
- Modify: `lib/ravner_web/live/admin_live/settings.ex`

- [ ] **Step 1: Refactor `Ravner.Scans` to use the shared runner**

In `lib/ravner/scans.ex`, add the alias near existing aliases:

```elixir
alias Ravner.SystemCommand
```

Change `do_dnsx_scan/1` to call the shared runner:

```elixir
case SystemCommand.run_with_timeout("dnsx", args, @dnsx_timeout) do
```

Change `do_whois_scan/1` to call the shared runner:

```elixir
case SystemCommand.run_with_timeout("whois", [domain_name], @whois_timeout) do
```

Delete these private functions from `Ravner.Scans`:

```elixir
cmd_with_timeout/3
collect_port_output/3
close_port/1
```

- [ ] **Step 2: Refactor `Ravner.Scans.SecurityRunner`**

In `lib/ravner/scans/security_runner.ex`, add:

```elixir
alias Ravner.SystemCommand
```

Replace calls like:

```elixir
cmd_with_timeout("httpx", args, [stderr_to_stdout: true], @scan_timeout)
```

with:

```elixir
SystemCommand.run_with_timeout("httpx", args, @scan_timeout)
```

Apply the same replacement for `naabu` and `nuclei`.

Delete the local timeout implementation from `SecurityRunner`:

```elixir
cmd_with_timeout/4
collect_port_output/3
close_port/1
kill_process_group/1
escape_args/1
shell_escape/1
```

- [ ] **Step 3: Refactor admin settings update**

In `lib/ravner_web/live/admin_live/settings.ex`, add:

```elixir
alias Ravner.SystemCommand
```

Change:

```elixir
defp update_nuclei_templates do
  cmd_with_timeout("nuclei", ["-update-templates"], @nuclei_template_update_timeout)
end
```

to:

```elixir
defp update_nuclei_templates do
  SystemCommand.run_with_timeout(
    "nuclei",
    ["-update-templates"],
    @nuclei_template_update_timeout
  )
end
```

Delete the local admin timeout helpers:

```elixir
cmd_with_timeout/3
collect_port_output/3
close_port/1
```

- [ ] **Step 4: Run targeted tests and compile**

Run:

```bash
mix test test/ravner/system_command_test.exs test/ravner/security_scans_test.exs
mix compile --warnings-as-errors
```

Expected: tests and compile pass.

- [ ] **Step 5: Commit**

```bash
git add lib/ravner/scans.ex lib/ravner/scans/security_runner.ex lib/ravner_web/live/admin_live/settings.ex
git commit -m "refactor(scans): use shared command runner"
```

---

### Task 3: Add Scan Pipeline Boundary and Configurable Concurrency

**Files:**
- Modify: `lib/ravner/scans.ex`
- Modify: `lib/ravner_web/live/domain_live/index.ex`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`
- Test: `test/ravner/scans_test.exs`

- [ ] **Step 1: Add tests for `scan_max_concurrency/0`**

Create `test/ravner/scans_test.exs` if it does not exist:

```elixir
defmodule Ravner.ScansTest do
  use ExUnit.Case, async: false

  alias Ravner.Scans

  setup do
    original = Application.get_env(:ravner, :scan_max_concurrency)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:ravner, :scan_max_concurrency)
      else
        Application.put_env(:ravner, :scan_max_concurrency, original)
      end
    end)

    :ok
  end

  test "scan_max_concurrency returns configured positive integer" do
    Application.put_env(:ravner, :scan_max_concurrency, 3)

    assert Scans.scan_max_concurrency() == 3
  end

  test "scan_max_concurrency defaults to five when config is missing" do
    Application.delete_env(:ravner, :scan_max_concurrency)

    assert Scans.scan_max_concurrency() == 5
  end

  test "scan_max_concurrency falls back to five for invalid config" do
    Application.put_env(:ravner, :scan_max_concurrency, 0)

    assert Scans.scan_max_concurrency() == 5
  end
end
```

- [ ] **Step 2: Run new test to verify it fails**

Run:

```bash
mix test test/ravner/scans_test.exs
```

Expected: compilation fails because `Scans.scan_max_concurrency/0` is not defined.

- [ ] **Step 3: Add config defaults**

In `config/config.exs`, extend the existing general `config :ravner` block:

```elixir
config :ravner,
  ecto_repos: [Ravner.Repo],
  generators: [timestamp_type: :utc_datetime],
  scan_max_concurrency: 5
```

In `config/runtime.exs`, replace the final single-key config:

```elixir
config :ravner, :chaos_api_key, System.get_env("CHAOS_API_KEY")
```

with:

```elixir
config :ravner,
  chaos_api_key: System.get_env("CHAOS_API_KEY"),
  scan_max_concurrency:
    System.get_env("SCAN_MAX_CONCURRENCY", "5")
    |> String.to_integer()
```

- [ ] **Step 4: Add scan orchestration helpers**

In `lib/ravner/scans.ex`, add near the public scan functions:

```elixir
@spec run_quick_scan(integer()) :: %{atom() => {:ok, term()} | {:error, term()}}
def run_quick_scan(domain_id) do
  %{
    dnsx: run_dnsx_scan(domain_id),
    httpx: run_httpx_scan(domain_id),
    rdap: run_rdap_scan(domain_id),
    subdomains: run_subdomain_scan(domain_id)
  }
end

@spec scan_max_concurrency() :: pos_integer()
def scan_max_concurrency do
  case Application.get_env(:ravner, :scan_max_concurrency, 5) do
    value when is_integer(value) and value > 0 -> value
    _ -> 5
  end
end
```

- [ ] **Step 5: Update LiveView quick scan calls**

In `lib/ravner_web/live/domain_live/index.ex`, replace the single-domain quick scan body:

```elixir
Scans.run_dnsx_scan(domain_id)
Scans.run_httpx_scan(domain_id)
Scans.run_rdap_scan(domain_id)
Scans.run_subdomain_scan(domain_id)
send(liveview_pid, {:quick_scan_done, domain_id})
```

with:

```elixir
Scans.run_quick_scan(domain_id)
send(liveview_pid, {:quick_scan_done, domain_id})
```

Replace the bulk scan per-domain body:

```elixir
Scans.run_dnsx_scan(domain.id)
Scans.run_httpx_scan(domain.id)
Scans.run_rdap_scan(domain.id)
Scans.run_subdomain_scan(domain.id)
send(liveview_pid, {:quick_scan_done, domain.id})
```

with:

```elixir
Scans.run_quick_scan(domain.id)
send(liveview_pid, {:quick_scan_done, domain.id})
```

Replace:

```elixir
max_concurrency: 10,
```

with:

```elixir
max_concurrency: Scans.scan_max_concurrency(),
```

- [ ] **Step 6: Run targeted tests**

Run:

```bash
mix test test/ravner/scans_test.exs test/ravner_web/live/domain_live/index_test.exs
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add config/config.exs config/runtime.exs lib/ravner/scans.ex lib/ravner_web/live/domain_live/index.ex test/ravner/scans_test.exs
git commit -m "feat(scans): centralize quick scan orchestration"
```

---

### Task 4: Route Combined Show Scans Through Scan Context

**Files:**
- Modify: `lib/ravner_web/live/domain_live/show.ex`
- Test: `test/ravner_web/live/domain_live/show_test.exs`

This task keeps individual scan buttons unchanged, but routes the combined scan path through the new boundary while still sending the same per-step messages to the LiveView.

- [ ] **Step 1: Update combined scan task helper**

In `lib/ravner_web/live/domain_live/show.ex`, keep individual handlers such as `"scan_dnsx"` and `"scan_httpx"` as they are. Replace `start_scan_tasks/2` with:

```elixir
defp start_scan_tasks(pid, id) do
  start_background_scan(fn ->
    results = Scans.run_quick_scan(id)

    send(pid, {:scan_done, :dnsx, Map.fetch!(results, :dnsx)})
    send(pid, {:scan_done, :httpx, Map.fetch!(results, :httpx)})
    send(pid, {:scan_done, :rdap, Map.fetch!(results, :rdap)})
    send(pid, {:scan_done, :subdomains, Map.fetch!(results, :subdomains)})
  end)
end
```

- [ ] **Step 2: Run show tests**

Run:

```bash
mix test test/ravner_web/live/domain_live/show_test.exs
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add lib/ravner_web/live/domain_live/show.ex test/ravner_web/live/domain_live/show_test.exs
git commit -m "refactor(domains): route combined scans through scan context"
```

---

### Task 5: Final Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run formatter**

Run:

```bash
mix format
```

Expected: command exits successfully.

- [ ] **Step 2: Run precommit**

Run:

```bash
mix precommit
```

Expected: all checks pass.

- [ ] **Step 3: Inspect final status**

Run:

```bash
git status --short
git log --oneline -5
```

Expected: only intentional formatted changes are present before the final commit, and the recent commits match the task sequence.

- [ ] **Step 4: Commit final formatting if needed**

If `mix format` changed files that were not committed by earlier tasks:

```bash
git add .
git commit -m "style: format scan command changes"
```

If there are no pending changes, skip this commit.

---

## Self-Review

- Spec coverage: the plan covers the shared command runner, scan pipeline boundary, configurable concurrency, runtime config, tests, and final `mix precommit`.
- Placeholder scan: no `TBD`, broad "handle edge cases", or unspecified implementation steps remain.
- Type consistency: `run_with_timeout/4`, `run_quick_scan/1`, and `scan_max_concurrency/0` are named consistently across tasks.
