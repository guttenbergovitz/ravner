defmodule Ravner.ActivityLog do
  @moduledoc """
  PubSub-based activity broadcaster for real-time system status.

  Scanners call `emit/2` to broadcast step-by-step progress to connected
  LiveViews. The user_id is resolved from the process dictionary (set by
  the calling LiveView via `set_user/1`).
  """

  @pubsub Ravner.PubSub

  @type level :: :step | :done | :error

  @doc "Subscribe the current process to activity messages for a user."
  @spec subscribe(integer() | String.t()) :: :ok | {:error, term()}
  def subscribe(user_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(user_id))
  end

  @doc "Set the current user_id in the process dictionary for implicit emission."
  @spec set_user(integer() | String.t()) :: :ok
  def set_user(user_id) do
    Process.put(:activity_user_id, user_id)
    :ok
  end

  @doc "Emit a message to the user set via `set_user/1`. No-op if no user set."
  @spec emit(level(), String.t()) :: :ok
  def emit(level, message) do
    case Process.get(:activity_user_id) do
      nil -> :ok
      user_id -> emit(user_id, level, message)
    end
  end

  @doc "Emit a message to a specific user."
  @spec emit(integer() | String.t(), level(), String.t()) :: :ok
  def emit(user_id, level, message) when level in [:step, :done, :error] do
    Phoenix.PubSub.broadcast(@pubsub, topic(user_id), {:activity, level, message, now()})
    :ok
  end

  defp topic(user_id), do: "activity:user:#{user_id}"

  defp now, do: DateTime.utc_now() |> Calendar.strftime("%H:%M:%S")
end
