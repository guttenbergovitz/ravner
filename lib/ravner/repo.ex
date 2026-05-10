defmodule Ravner.Repo do
  use Ecto.Repo,
    otp_app: :ravner,
    adapter: Ecto.Adapters.Postgres

  def installed_extensions do
    ["ash-functions"]
  end

  def disable_atomic_actions? do
    false
  end

  def prefer_transaction? do
    true
  end

  def disable_expr_error? do
    false
  end

  def on_transaction_begin(_reason) do
    :ok
  end

  def default_constraint_match_type(_type, _name) do
    :exact
  end
end
