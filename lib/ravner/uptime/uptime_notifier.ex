defmodule Ravner.Uptime.UptimeNotifier do
  @moduledoc """
  Builds and delivers uptime notification emails.
  """
  import Swoosh.Email
  alias Ravner.Mailer

  defp sender do
    from_email =
      Application.get_env(
        :ravner,
        :uptime_mail_from,
        Application.get_env(:ravner, :mail_from, "noreply@example.com")
      )

    from_name = Application.get_env(:ravner, :uptime_mail_from_name, "Ravner Uptime")
    {from_name, from_email}
  end

  defp base_url do
    RavnerWeb.Endpoint.url()
  end

  def deliver_incident_open(to_email, domain_name, started_at, opts \\ []) do
    domain_id = Keyword.get(opts, :domain_id)
    link = if domain_id, do: "#{base_url()}/uptime/#{domain_id}", else: "#{base_url()}/uptime"

    new()
    |> to(to_email)
    |> from(sender())
    |> subject("[DOWN] #{domain_name} is unreachable")
    |> text_body("""
    INCIDENT OPEN

    Domain: #{domain_name}
    Status: DOWN
    Since:  #{Calendar.strftime(started_at, "%Y-%m-%d %H:%M UTC")}

    We detected multiple consecutive failures. Monitoring will continue
    and you'll be notified when the domain recovers.

    View details: #{link}

    — Ravner Uptime Monitor
    """)
    |> Mailer.deliver()
  end

  def deliver_incident_resolved(to_email, domain_name, started_at, ended_at, duration_seconds, opts \\ []) do
    domain_id = Keyword.get(opts, :domain_id)
    link = if domain_id, do: "#{base_url()}/uptime/#{domain_id}", else: "#{base_url()}/uptime"

    new()
    |> to(to_email)
    |> from(sender())
    |> subject("[RECOVERED] #{domain_name} is back up")
    |> text_body("""
    INCIDENT RESOLVED

    Domain:   #{domain_name}
    Status:   UP (recovered)
    Down:     #{Calendar.strftime(started_at, "%Y-%m-%d %H:%M UTC")}
    Resolved: #{Calendar.strftime(ended_at, "%Y-%m-%d %H:%M UTC")}
    Duration: #{format_duration(duration_seconds)}

    View details: #{link}

    — Ravner Uptime Monitor
    """)
    |> Mailer.deliver()
  end

  def deliver_still_down(to_email, domain_name, started_at, reminder_number, opts \\ []) do
    domain_id = Keyword.get(opts, :domain_id)
    link = if domain_id, do: "#{base_url()}/uptime/#{domain_id}", else: "#{base_url()}/uptime"

    new()
    |> to(to_email)
    |> from(sender())
    |> subject("[STILL DOWN] #{domain_name} — reminder ##{reminder_number}")
    |> text_body("""
    STILL DOWN (Reminder ##{reminder_number})

    Domain: #{domain_name}
    Status: DOWN
    Since:  #{Calendar.strftime(started_at, "%Y-%m-%d %H:%M UTC")}

    The domain has not recovered yet.

    View details: #{link}

    — Ravner Uptime Monitor
    """)
    |> Mailer.deliver()
  end

  defp format_duration(nil), do: "unknown"
  defp format_duration(s) when s < 60, do: "#{s} seconds"
  defp format_duration(s) when s < 3600, do: "#{div(s, 60)} minutes"
  defp format_duration(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
end
