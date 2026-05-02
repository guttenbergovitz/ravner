defmodule Ravner.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Load .env file in development
    if Application.get_env(:ravner, :env) == :dev do
      Dotenvy.source([".env", ".env.dev", ".env.#{Application.get_env(:ravner, :env)}"])
    end

    children = [
      RavnerWeb.Telemetry,
      Ravner.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:ravner, :ecto_repos),
       skip: System.get_env("SKIP_MIGRATIONS") == "true"},
      {DNSCluster, query: Application.get_env(:ravner, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Ravner.PubSub},
      # Start a worker by calling: Ravner.Worker.start_link(arg)
      # {Ravner.Worker, arg},
      # Start to serve requests, typically the last entry
      RavnerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ravner.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RavnerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
