defmodule Ravner.Workers.TechnologiesUpdateWorkerTest do
  use ExUnit.Case, async: false

  alias Ravner.Workers.TechnologiesUpdateWorker

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "tech_update_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "technologies.json")

    original_path = Application.get_env(:ravner, :wappalyzer_technologies_path)
    original_opts = Application.get_env(:ravner, :wappalyzer_req_opts)
    original_min = Application.get_env(:ravner, :wappalyzer_min_technologies)

    Application.put_env(:ravner, :wappalyzer_technologies_path, path)
    Application.put_env(:ravner, :wappalyzer_min_technologies, 2)

    on_exit(fn ->
      File.rm_rf(tmp_dir)
      restore_env(:wappalyzer_technologies_path, original_path)
      restore_env(:wappalyzer_req_opts, original_opts)
      restore_env(:wappalyzer_min_technologies, original_min)
    end)

    {:ok, path: path}
  end

  defp restore_env(key, nil), do: Application.delete_env(:ravner, key)
  defp restore_env(key, value), do: Application.put_env(:ravner, key, value)

  defp with_stubbed_upstream(fun) do
    test_pid = self()

    plug = fn conn ->
      send(test_pid, {:upstream_request, conn})
      fun.(conn)
    end

    Application.put_env(:ravner, :wappalyzer_req_opts, plug: plug)
  end

  defp valid_body do
    Jason.encode!(%{
      "technologies" => %{
        "WordPress" => %{"cats" => [1]},
        "Cloudflare" => %{"cats" => [32]}
      },
      "categories" => %{}
    })
  end

  test "downloads, validates and stores the technologies file", %{path: path} do
    with_stubbed_upstream(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, valid_body())
    end)

    assert :ok = TechnologiesUpdateWorker.perform(%Oban.Job{})
    assert_received {:upstream_request, _conn}

    assert {:ok, %{"technologies" => techs}} = path |> File.read!() |> Jason.decode()
    assert map_size(techs) == 2
  end

  test "fails when upstream returns an error status", %{path: path} do
    with_stubbed_upstream(fn conn -> Plug.Conn.send_resp(conn, 404, "not found") end)

    assert {:error, reason} = TechnologiesUpdateWorker.perform(%Oban.Job{})
    assert reason =~ "404"
    refute File.exists?(path)
  end

  test "rejects truncated files", %{path: path} do
    with_stubbed_upstream(fn conn ->
      Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"technologies" => %{"OnlyOne" => %{}}}))
    end)

    assert {:error, reason} = TechnologiesUpdateWorker.perform(%Oban.Job{})
    assert reason =~ "truncated"
    refute File.exists?(path)
  end

  test "rejects invalid JSON", %{path: path} do
    with_stubbed_upstream(fn conn -> Plug.Conn.send_resp(conn, 200, "{oops") end)

    assert {:error, reason} = TechnologiesUpdateWorker.perform(%Oban.Job{})
    assert reason =~ "invalid JSON"
    refute File.exists?(path)
  end
end
