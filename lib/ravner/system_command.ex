defmodule Ravner.SystemCommand do
  @moduledoc """
  Runs external commands with timeout and process-group cleanup.
  """

  @type result :: {String.t(), non_neg_integer()} | {:error, :timeout} | {:error, String.t()}

  @spec run_with_timeout(String.t(), [String.t()], non_neg_integer(), keyword()) :: result()
  def run_with_timeout(command, args, timeout, opts \\ [])
      when is_binary(command) and is_list(args) and is_integer(timeout) and timeout >= 0 do
    stdin = Keyword.get(opts, :stdin, :dev_null)
    env = Keyword.get(opts, :env, [])

    with {:ok, executable} <- find_executable(command),
         {:ok, {runner_path, runner_args_prefix}} <- find_setsid_runner() do
      shell_cmd = build_shell_command(executable, args, stdin)

      port_env =
        Enum.map(env, fn {k, v} ->
          {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
        end)

      port_opts =
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: runner_args_prefix ++ ["/bin/bash", "-c", shell_cmd]
        ]
        |> then(fn base ->
          if port_env == [], do: base, else: Keyword.put(base, :env, port_env)
        end)

      port = Port.open({:spawn_executable, runner_path}, port_opts)

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
      nil ->
        if File.exists?(command) and not File.dir?(command) do
          {:ok, command}
        else
          {:error, "#{command} executable not found"}
        end

      executable ->
        {:ok, executable}
    end
  end

  defp find_setsid_runner do
    perl_script = "use POSIX qw(setsid); setsid(); exec @ARGV"

    cond do
      perl_path = System.find_executable("perl") ->
        {:ok, {perl_path, ["-e", perl_script, "--"]}}

      setsid_path = System.find_executable("setsid") ->
        {:ok, {setsid_path, []}}

      true ->
        {:error, "neither perl nor setsid executable found"}
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

  # Sends SIGTERM synchronously and schedules a SIGKILL escalation under
  # Task.Supervisor so the cleanup survives caller crashes and is properly
  # supervised. The grace period (500ms) allows the process to exit cleanly.
  defp kill_process_group(os_pid) do
    pgid_arg = "-#{os_pid}"
    _ = System.cmd("kill", ["-TERM", "--", pgid_arg], stderr_to_stdout: true)

    # Use Task.Supervisor to ensure SIGKILL fires even if caller crashes
    Task.Supervisor.start_child(
      Ravner.ScanTaskSupervisor,
      fn ->
        Process.sleep(500)
        _ = System.cmd("kill", ["-KILL", "--", pgid_arg], stderr_to_stdout: true)
      end,
      restart: :temporary
    )

    :ok
  end

  defp escape_args(args) do
    Enum.map_join(args, " ", &shell_escape/1)
  end

  defp shell_escape(arg) do
    arg = to_string(arg)

    if String.match?(arg, ~r/^[a-zA-Z0-9_.~+=@\/-]+$/) do
      arg
    else
      "'" <> String.replace(arg, "'", "'\"'\"'") <> "'"
    end
  end
end
