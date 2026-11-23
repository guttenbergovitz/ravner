defmodule Ravner.Repo do
  @moduledoc """
  PostgreSQL database repository for Ravner.

  Configured with `ash-functions` extensions to support Ash Framework
  data layers alongside standard Ecto queries.
  """
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

  def prefer_transaction_for_atomic_updates? do
    true
  end

  def default_constraint_match_type(_type, _name) do
    :exact
  end
end
