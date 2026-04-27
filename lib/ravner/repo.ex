defmodule Ravner.Repo do
  use Ecto.Repo,
    otp_app: :ravner,
    adapter: Ecto.Adapters.Postgres
end
