defmodule Ravner.Notifications do
  @moduledoc """
  Unified notification and alerting facade for security vulnerabilities,
  credential leaks, SSL expiration warnings, and multi-channel chatops.
  """

  import Ecto.Query
  require Logger

  alias Ravner.Repo
  alias Ravner.Uptime.{NotificationPolicy, NotificationRecipient}
  alias Ravner.Workers.WebhookNotificationWorker

  @doc """
  Dispatches a security event alert to all relevant notification policy recipients
  via the Oban `:notifications` queue.
  """
  @spec dispatch_security_event(atom() | String.t(), map(), keyword()) ::
          {:ok, [Oban.Job.t()]} | {:error, term()}
  def dispatch_security_event(event_type, payload, _opts \\ []) do
    domain_id = Map.get(payload, :domain_id) || Map.get(payload, "domain_id")
    recipients = resolve_alert_recipients(domain_id)

    webhook_recipients =
      Enum.filter(recipients, fn r ->
        (r.channels in ["webhook", "all"] or not is_nil(r.webhook_url)) and
          is_binary(r.webhook_url) and r.webhook_url != ""
      end)

    event_str = to_string(event_type)

    jobs =
      for r <- webhook_recipients do
        dedup_key = Map.get(payload, :dedup_key) || Map.get(payload, "dedup_key")

        args =
          %{
            "recipient_id" => r.id,
            "event_type" => event_str,
            "payload" => payload
          }
          |> maybe_put_dedup_key(dedup_key)

        job_opts =
          if dedup_key do
            [
              unique: [
                fields: [:args, :queue, :worker],
                period: 3600,
                keys: [:event_type, :dedup_key, :recipient_id],
                states: [:available, :scheduled, :executing, :retryable]
              ]
            ]
          else
            []
          end

        job =
          args
          |> WebhookNotificationWorker.new(job_opts)
          |> Oban.insert()

        case job do
          {:ok, j} ->
            j

          {:error, reason} ->
            Logger.warning("Failed to enqueue webhook notification: #{inspect(reason)}")
            nil
        end
      end
      |> Enum.reject(&is_nil/1)

    {:ok, jobs}
  end

  @doc """
  Dispatches an alert when critical CVEs are identified in repository dependencies.
  """
  @spec dispatch_critical_vulnerabilities(map(), [map()], keyword()) ::
          {:ok, [Oban.Job.t()]} | {:error, term()}
  def dispatch_critical_vulnerabilities(repo, vulnerability_attrs, opts \\ []) do
    criticals =
      Enum.filter(vulnerability_attrs, fn v ->
        Map.get(v, :severity) == "critical" or Map.get(v, "severity") == "critical"
      end)

    if criticals != [] do
      first = hd(criticals)
      repo_name = Map.get(repo, :name) || Map.get(repo, :external_id) || repo.url
      cve_id = Map.get(first, :cve_id) || Map.get(first, "cve_id")
      pkg_name = Map.get(first, :package_name) || Map.get(first, "package_name")
      pkg_ver = Map.get(first, :package_version) || Map.get(first, "package_version")

      title =
        Map.get(first, :title) || Map.get(first, :summary) || Map.get(first, "title") ||
          Map.get(first, "summary")

      payload = %{
        event: "vulnerability_critical",
        repository_id: repo.id,
        repository_name: repo_name,
        repository_url: repo.url,
        project_id: repo.project_id,
        domain_id: repo.domain_id,
        critical_count: length(criticals),
        cve_id: cve_id,
        package_name: pkg_name,
        package_version: pkg_ver,
        title: title,
        dedup_key: "cve:#{repo.id}:#{cve_id}",
        ravner_url: build_repo_url(repo)
      }

      dispatch_security_event(:vulnerability_critical, payload, opts)
    else
      {:ok, []}
    end
  end

  @doc """
  Dispatches an alert when active leaked secrets or credentials are discovered in VCS.
  """
  @spec dispatch_secret_leaks(map(), [map()], keyword()) ::
          {:ok, [Oban.Job.t()]} | {:error, term()}
  def dispatch_secret_leaks(repo, active_findings, opts \\ []) do
    active =
      Enum.filter(active_findings, fn s ->
        Map.get(s, :status) == "active" or Map.get(s, "status") == "active"
      end)

    if active != [] do
      first = hd(active)
      repo_name = Map.get(repo, :name) || Map.get(repo, :external_id) || repo.url
      file_path = Map.get(first, :file_path) || Map.get(first, "file_path")
      line_number = Map.get(first, :line_number) || Map.get(first, "line_number")
      rule_name = Map.get(first, :rule_name) || Map.get(first, "rule_name")
      masked_value = Map.get(first, :masked_value) || Map.get(first, "masked_value")
      fingerprint = Map.get(first, :fingerprint_sha256) || Map.get(first, "fingerprint_sha256")

      payload = %{
        event: "secret_leak",
        repository_id: repo.id,
        repository_name: repo_name,
        repository_url: repo.url,
        project_id: repo.project_id,
        domain_id: repo.domain_id,
        leaks_count: length(active),
        file_path: file_path,
        line_number: line_number,
        rule_name: rule_name,
        masked_value: masked_value,
        dedup_key: "secret:#{repo.id}:#{fingerprint}",
        ravner_url: build_repo_url(repo)
      }

      dispatch_security_event(:secret_leak, payload, opts)
    else
      {:ok, []}
    end
  end

  @doc """
  Dispatches an alert when an SSL certificate is expiring in <= 14 days.
  """
  @spec dispatch_ssl_expiry(integer(), String.t(), map(), keyword()) ::
          {:ok, [Oban.Job.t()]} | {:error, term()}
  def dispatch_ssl_expiry(domain_id, domain_name, ssl_data, opts \\ []) do
    days = Map.get(ssl_data, :ssl_days_remaining) || Map.get(ssl_data, "ssl_days_remaining")

    if is_integer(days) and days <= 14 do
      payload = %{
        event: "ssl_expiry",
        domain_id: domain_id,
        domain_name: domain_name,
        days_remaining: days,
        issuer: Map.get(ssl_data, :ssl_issuer) || Map.get(ssl_data, "ssl_issuer"),
        valid_until: Map.get(ssl_data, :ssl_valid_until) || Map.get(ssl_data, "ssl_valid_until"),
        dedup_key: "ssl:#{domain_id}:#{days}",
        ravner_url: build_domain_url(domain_id)
      }

      dispatch_security_event(:ssl_expiry, payload, opts)
    else
      {:ok, []}
    end
  end

  @doc """
  Sends a synchronous test webhook message to verify configuration.
  """
  @spec send_test_webhook(NotificationRecipient.t() | integer(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def send_test_webhook(recipient_or_id, opts \\ [])

  def send_test_webhook(recipient_id, opts) when is_integer(recipient_id) do
    case Repo.get(NotificationRecipient, recipient_id) do
      nil -> {:error, :recipient_not_found}
      recipient -> send_test_webhook(recipient, opts)
    end
  end

  def send_test_webhook(%NotificationRecipient{} = recipient, opts) do
    payload = %{
      event: "test",
      message: "Test webhook from Ravner enterprise security & uptime alerting.",
      sent_at: DateTime.utc_now(),
      recipient_id: recipient.id
    }

    Ravner.Notifications.WebhookDispatcher.deliver_event(recipient, "test", payload, opts)
  end

  # ── Recipient Resolution ───────────────────────────────────────────────────

  defp resolve_alert_recipients(domain_id) when is_integer(domain_id) do
    case Ravner.Uptime.Notifications.resolve_recipients(domain_id) do
      [] -> list_global_recipients()
      recipients -> recipients
    end
  end

  defp resolve_alert_recipients(_), do: list_global_recipients()

  defp list_global_recipients do
    case Repo.one(from p in NotificationPolicy, where: p.scope == "global" and p.enabled == true) do
      nil ->
        []

      %NotificationPolicy{} = policy ->
        NotificationRecipient
        |> where(policy_id: ^policy.id)
        |> Repo.all()
    end
  end

  defp maybe_put_dedup_key(args, nil), do: args
  defp maybe_put_dedup_key(args, dedup_key), do: Map.put(args, "dedup_key", dedup_key)

  defp build_domain_url(nil), do: nil

  defp build_domain_url(domain_id) do
    base = RavnerWeb.Endpoint.url()
    "#{base}/domains/#{domain_id}"
  rescue
    _ -> nil
  end

  defp build_repo_url(repo) do
    base = RavnerWeb.Endpoint.url()

    if repo.project_id do
      "#{base}/admin/projects/#{repo.project_id}"
    else
      "#{base}/admin/repositories"
    end
  rescue
    _ -> nil
  end
end
