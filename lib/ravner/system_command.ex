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

  # Sends SIGTERM synchronously and schedules a SIGKILL escalation in a detached
  # process so the caller (typically an Oban worker) is not blocked waiting for
  # the grace period to elapse.
  defp kill_process_group(os_pid) do
    pgid_arg = "-#{os_pid}"
    _ = System.cmd("kill", ["-TERM", "--", pgid_arg], stderr_to_stdout: true)

    spawn(fn ->
      Process.sleep(500)
      _ = System.cmd("kill", ["-KILL", "--", pgid_arg], stderr_to_stdout: true)
    end)

    :ok
  end

  defp escape_args(args) do
    args
    |> Enum.map(&shell_escape/1)
    |> Enum.join(" ")
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
