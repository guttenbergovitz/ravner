defmodule Ravner.Uptime.Notifications do
  @moduledoc """
  Resolves notification policies and dispatches alerts for uptime events.
  """

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Uptime.NotificationPolicy
  alias Ravner.Uptime.NotificationRecipient
  alias Ravner.Uptime.NotificationDelivery
  alias Ravner.Uptime.DowntimeWindow
  alias Ravner.Uptime.UptimeNotifier
  alias Ravner.Uptime.SmsAdapter

  @doc """
  Dispatches notifications for an event. Enqueues an Oban worker for async delivery.
  """
  def dispatch(event, %DowntimeWindow{} = window) do
    %{event: event, downtime_window_id: window.id, domain_id: window.domain_id}
    |> Ravner.Workers.UptimeNotificationWorker.new()
    |> Oban.insert()
  end

  @doc """
  Resolves recipients for a domain based on policy precedence:
  per-domain > group > global.
  """
  def resolve_recipients(domain_id) do
    case get_policy("domain", domain_id) do
      %NotificationPolicy{} = policy ->
        recipients_for_policy(policy)

      nil ->
        # ponytail: group-level skipped for MVP; upgrade path: domain_group_memberships join
        case get_policy("global", nil) do
          %NotificationPolicy{} = policy -> recipients_for_policy(policy)
          nil -> []
        end
    end
  end

  @doc """
  Delivers a notification to a single recipient for an event.
  Checks idempotency before sending.
  """
  def deliver_to_recipient(recipient, event, window, opts \\ []) do
    sequence = Keyword.get(opts, :sequence, 0)
    domain_name = Keyword.get(opts, :domain_name, "unknown")

    channels = expand_channels(recipient)
    email = resolve_email(recipient)
    phone = resolve_phone(recipient)

    for channel <- channels do
      unless already_delivered?(window.id, recipient.id, event, sequence, channel) do
        result =
          send_via_channel(
            channel,
            email,
            phone,
            recipient,
            event,
            window,
            domain_name,
            sequence,
            opts
          )

        %NotificationDelivery{
          downtime_window_id: window.id,
          recipient_id: recipient.id,
          event_type: event,
          sequence: sequence,
          channel: channel,
          delivered_at: if(match?({:ok, _}, result), do: DateTime.utc_now(:second)),
          error:
            case result do
              {:error, reason} -> inspect(reason)
              _ -> nil
            end
        }
        |> Repo.insert!(on_conflict: :nothing)
      end
    end
  end

  # --- Private ---

  defp get_policy(scope, domain_id) do
    query =
      NotificationPolicy
      |> where(scope: ^scope)
      |> where(enabled: true)

    query = if domain_id, do: where(query, domain_id: ^domain_id), else: query

    query
    |> limit(1)
    |> Repo.one()
  end

  defp recipients_for_policy(policy) do
    direct =
      NotificationRecipient
      |> where(policy_id: ^policy.id)
      |> Repo.all()
      |> Repo.preload(:user)

    group_ids =
      from(pg in "uptime_policy_groups",
        where: pg.policy_id == ^policy.id,
        select: pg.group_id
      )
      |> Repo.all()

    group_recipients =
      if group_ids != [] do
        NotificationRecipient
        |> where([r], r.group_id in ^group_ids)
        |> Repo.all()
        |> Repo.preload(:user)
      else
        []
      end

    Enum.uniq_by(direct ++ group_recipients, & &1.id)
  end

  defp expand_channels(%{channels: "both"}), do: ["email", "sms"]
  defp expand_channels(%{channels: "all"}), do: ["email", "sms", "webhook"]
  defp expand_channels(%{channels: ch}) when is_binary(ch), do: [ch]
  defp expand_channels(_), do: ["email"]

  defp resolve_email(%{user: %{email: email}}) when is_binary(email), do: email
  defp resolve_email(%{email: email}) when is_binary(email), do: email
  defp resolve_email(_), do: nil

  defp resolve_phone(%{phone: phone}) when is_binary(phone), do: phone
  defp resolve_phone(_), do: nil

  defp send_via_channel(
         "email",
         email,
         _phone,
         _recipient,
         event,
         window,
         domain_name,
         sequence,
         _opts
       ) do
    if email do
      opts = [domain_id: window.domain_id]

      case event do
        "incident_open" ->
          UptimeNotifier.deliver_incident_open(email, domain_name, window.started_at, opts)

        "incident_resolved" ->
          UptimeNotifier.deliver_incident_resolved(
            email,
            domain_name,
            window.started_at,
            window.ended_at,
            window.duration_seconds,
            opts
          )

        "still_down" ->
          UptimeNotifier.deliver_still_down(email, domain_name, window.started_at, sequence, opts)
      end
    else
      {:error, :no_email}
    end
  end

  defp send_via_channel(
         "sms",
         _email,
         phone,
         _recipient,
         event,
         window,
         domain_name,
         _sequence,
         _opts
       ) do
    if phone do
      body =
        case event do
          "incident_open" ->
            "[DOWN] #{domain_name} is unreachable since #{Calendar.strftime(window.started_at, "%H:%M UTC")}"

          "incident_resolved" ->
            "[UP] #{domain_name} recovered at #{Calendar.strftime(window.ended_at, "%H:%M UTC")}"

          "still_down" ->
            "[STILL DOWN] #{domain_name} since #{Calendar.strftime(window.started_at, "%H:%M UTC")}"
        end

      SmsAdapter.send_sms(phone, body)
    else
      {:error, :no_phone}
    end
  end

  defp send_via_channel(
         "webhook",
         _email,
         _phone,
         recipient,
         event,
         window,
         domain_name,
         sequence,
         opts
       ) do
    if recipient.webhook_url do
      event_data = %{
        event: event,
        domain_name: domain_name,
        domain_id: window.domain_id,
        started_at: window.started_at,
        ended_at: window.ended_at,
        duration_seconds: window.duration_seconds,
        sequence: sequence,
        ravner_url: Keyword.get(opts, :ravner_url, build_domain_url(window.domain_id))
      }

      Ravner.Notifications.WebhookDispatcher.deliver_event(
        recipient,
        event,
        event_data,
        opts
      )
    else
      {:error, :no_webhook_url}
    end
  end

  defp build_domain_url(nil), do: nil

  defp build_domain_url(domain_id) do
    base = RavnerWeb.Endpoint.url()
    "#{base}/domains/#{domain_id}"
  rescue
    _e in [ArgumentError, RuntimeError] -> nil
  end

  defp already_delivered?(window_id, recipient_id, event, sequence, channel) do
    NotificationDelivery
    |> where(downtime_window_id: ^window_id)
    |> where(recipient_id: ^recipient_id)
    |> where(event_type: ^event)
    |> where(sequence: ^sequence)
    |> where(channel: ^channel)
    |> where([d], not is_nil(d.delivered_at))
    |> Repo.exists?()
  end
end
