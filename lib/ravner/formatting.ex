defmodule Ravner.Formatting do
  @moduledoc """
  Formatting helpers for display purposes.
  """

  @doc """
  Returns a human-readable relative time string for a past datetime.

  ## Examples

      iex> Ravner.Formatting.time_ago(DateTime.add(DateTime.utc_now(), -30, :second))
      "30s ago"

      iex> Ravner.Formatting.time_ago(DateTime.add(DateTime.utc_now(), -90, :second))
      "1m ago"

  """
  def time_ago(nil), do: "–"

  def time_ago(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds < 86_400 * 30 -> "#{div(seconds, 86_400)}d ago"
      seconds < 86_400 * 365 -> "#{div(seconds, 86_400 * 30)}mo ago"
      true -> "#{div(seconds, 86_400 * 365)}y ago"
    end
  end

  def time_ago(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> time_ago()
  end
end
