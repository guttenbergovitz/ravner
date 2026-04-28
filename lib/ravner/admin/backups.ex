defmodule Ravner.Admin.Backups do
  @moduledoc """
  Database backup and restore operations for business data only.
  Excludes authentication tables (users, users_tokens).
  """

  alias Ravner.Repo

  @exclude_tables ~w(users users_tokens)

  @doc """
  Creates a PostgreSQL custom-format dump of business data.
  Returns `{:ok, binary}` with the dump content, or `{:error, reason}`.
  """
  def create_dump do
    config = Repo.config()
    database = Keyword.get(config, :database)
    username = Keyword.get(config, :username, "postgres")
    password = Keyword.get(config, :password, "")
    hostname = Keyword.get(config, :hostname, "localhost")

    if is_nil(database) do
      {:error, "Database name not configured"}
    else
      tmp_path = Path.join(System.tmp_dir!(), "ravner_backup_#{timestamp()}.dump")

      args =
        [
          "-h",
          hostname,
          "-U",
          username,
          "-Fc"
        ] ++
          Enum.flat_map(@exclude_tables, &["--exclude-table", &1]) ++
          ["-f", tmp_path, database]

      env = if password != "", do: [{"PGPASSWORD", password}], else: []

      case System.cmd("pg_dump", args, env: env, stderr_to_stdout: true) do
        {_, 0} ->
          content = File.read!(tmp_path)
          File.rm(tmp_path)
          {:ok, content}

        {output, _} ->
          File.rm(tmp_path)
          {:error, output}
      end
    end
  end

  @doc """
  Restores business data from a PostgreSQL custom-format dump file.
  Uses `--clean --if-exists` to drop and recreate objects.

  **Warning**: this will overwrite existing business data.
  """
  def restore(path) when is_binary(path) do
    config = Repo.config()
    database = Keyword.get(config, :database)
    username = Keyword.get(config, :username, "postgres")
    password = Keyword.get(config, :password, "")
    hostname = Keyword.get(config, :hostname, "localhost")

    if is_nil(database) do
      {:error, "Database name not configured"}
    else
      args = [
        "-h",
        hostname,
        "-U",
        username,
        "-d",
        database,
        "--clean",
        "--if-exists",
        path
      ]

      env = if password != "", do: [{"PGPASSWORD", password}], else: []

      case System.cmd("pg_restore", args, env: env, stderr_to_stdout: true) do
        {_, 0} -> :ok
        {_output, 1} -> :ok
        {output, _} -> {:error, output}
      end
    end
  end

  @doc """
  Lists contents of a pg_dump custom-format file.
  Returns `{:ok, [String.t()]}` or `{:error, reason}`.
  """
  def list_dump_contents(path) when is_binary(path) do
    case System.cmd("pg_restore", ["--list", path], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      {output, _} -> {:error, output}
    end
  end

  defp timestamp do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%d_%H%M%S")
  end
end
