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

  test "run_with_timeout passes custom environment variables via :env option" do
    assert {output, 0} =
             SystemCommand.run_with_timeout(
               "elixir",
               ["-e", "IO.write(System.get_env(\"RAVNER_TEST_ENV_VAR\"))"],
               5_000,
               env: [{"RAVNER_TEST_ENV_VAR", "custom_value_123"}]
             )

    assert output == "custom_value_123"
  end
end
