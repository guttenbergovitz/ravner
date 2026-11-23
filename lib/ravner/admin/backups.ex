defmodule Ravner.Admin.Backups do
  @moduledoc """
  Database backup and restore operations for business data only.
  Excludes authentication tables (users, users_tokens).
  """

  alias Ravner.Repo

  @exclude_tables ~w(users users_tokens)

  @common_pg_paths [
    "/opt/homebrew/opt/postgresql@17/bin",
    "/opt/homebrew/opt/postgresql@16/bin",
    "/opt/homebrew/opt/postgresql@15/bin",
    "/usr/local/opt/postgresql@17/bin",
    "/usr/local/opt/postgresql@16/bin",
    "/usr/local/opt/postgresql@15/bin",
    "/Applications/Postgres.app/Contents/Versions/latest/bin"
  ]

  @doc """
  Creates a PostgreSQL custom-format dump of business data.
  Returns `{:ok, binary}` with the dump content, or `{:error, reason}`.
  """
  @spec create_dump() :: {:ok, binary()} | {:error, String.t()}
  def create_dump do
    config = Repo.config()
    database = Keyword.get(config, :database)
    username = Keyword.get(config, :username, "postgres")
    password = Keyword.get(config, :password, "")
    hostname = Keyword.get(config, :hostname, "localhost")

    with {:ok, db} <- check_database(database),
         tmp_path = Path.join(System.tmp_dir!(), "ravner_backup_#{timestamp()}.dump"),
         args = build_dump_args(hostname, username, db, tmp_path),
         env = if(password != "", do: [{"PGPASSWORD", password}], else: []),
         {_, 0} <- run_with_fallback("pg_dump", args, env) do
      read_and_clean_tmp(tmp_path)
    else
      {:error, reason} -> {:error, reason}
      {output, _code} -> {:error, normalize_pg_error(output)}
    end
  end

  defp check_database(nil), do: {:error, "Database name not configured"}
  defp check_database(db), do: {:ok, db}

  defp read_and_clean_tmp(tmp_path) do
    if File.exists?(tmp_path) do
      content = File.read!(tmp_path)
      File.rm(tmp_path)
      {:ok, content}
    else
      {:error, "pg_dump exited successfully but produced no output file"}
    end
  end

  @doc """
  Restores business data from a PostgreSQL custom-format dump file.
  Uses `--clean --if-exists` to drop and recreate objects.

  **Warning**: this will overwrite existing business data.
  """
  @spec restore(String.t()) :: :ok | {:error, String.t()}
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

      case run_with_fallback("pg_restore", args, env) do
        {_, 0} -> :ok
        {_output, 1} -> :ok
        {output, _} -> {:error, normalize_pg_error(output)}
      end
    end
  end

  @doc """
  Lists contents of a pg_dump custom-format file.
  Returns `{:ok, [String.t()]}` or `{:error, reason}`.
  """
  @spec list_dump_contents(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_dump_contents(path) when is_binary(path) do
    case run_with_fallback("pg_restore", ["--list", path], []) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      {output, _} -> {:error, normalize_pg_error(output)}
    end
  end

  defp build_dump_args(hostname, username, database, tmp_path) do
    [
      "-h",
      hostname,
      "-U",
      username,
      "-Fc"
    ] ++
      Enum.flat_map(@exclude_tables, &["--exclude-table", &1]) ++
      ["-f", tmp_path, database]
  end

  # Runs `cmd args` capturing stdout+stderr. If the binary is missing or
  # exits with a "version mismatch" message, falls back to a list of
  # well-known Postgres install paths and retries with the first match.
  defp run_with_fallback(cmd, args, env) do
    case safe_cmd(cmd, args, env) do
      {:ok, {_, 0} = ok} -> ok
      {:ok, result} -> try_fallback(cmd, args, env, result)
      {:error, :not_found} -> find_and_run(cmd, args, env)
    end
  end

  defp safe_cmd(cmd, args, env) do
    case Ravner.SystemCommand.run_with_timeout(cmd, args, 120_000, env: env) do
      {:error, :timeout} -> {:ok, {"Backup command timed out after 120s", 1}}
      {:error, _reason} -> {:error, :not_found}
      {output, status} -> {:ok, {output, status}}
    end
  end

  defp try_fallback(cmd, args, env, original_result) do
    {output, _} = original_result

    if String.contains?(output, "version mismatch") ||
         String.contains?(output, "aborting because of server version mismatch") do
      find_and_run(cmd, args, env)
    else
      original_result
    end
  end

  defp find_and_run(cmd, args, env) do
    case find_compatible_binary(cmd) do
      nil ->
        {version_msg(), 1}

      path ->
        case safe_cmd(path, args, env) do
          {:ok, result} -> result
          {:error, :not_found} -> {version_msg(), 1}
        end
    end
  end

  defp find_compatible_binary(cmd) do
    @common_pg_paths
    |> Enum.map(&Path.join(&1, cmd))
    |> Enum.find(&File.exists?/1)
  end

  defp version_msg do
    """
    PostgreSQL client tools version mismatch.

    Your pg_dump/pg_restore is older than the PostgreSQL server.
    Install matching client tools, for example:

      brew install postgresql@17

    Or add the bin directory to your PATH:

      export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
    """
  end

  defp normalize_pg_error(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
  end

  defp timestamp do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%d_%H%M%S")
  end
end
