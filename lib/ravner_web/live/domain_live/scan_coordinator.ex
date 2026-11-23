defmodule RavnerWeb.DomainLive.ScanCoordinator do
  @moduledoc """
  Coordinates scanning pipelines, background workers, and scan telemetry completion
  for DomainLive.Show and ScanPanel LiveComponent.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]
  require Logger

  alias Ravner.A11y
  alias Ravner.Domains
  alias Ravner.Domains.Domain
  alias Ravner.Lighthouse
  alias Ravner.Scans

  # Flash helper that works for both LiveView and LiveComponent.
  # Sends message to self() (the LiveView process) and puts flash on socket.
  defp notify_flash(socket, kind, msg) do
    send(self(), {:put_flash, kind, msg})
    put_flash(socket, kind, msg)
  end

  # ─── Permission Check ──────────────────────────────────────────────────────

  def can_scan?(socket) do
    case socket.assigns[:can_scan?] do
      nil ->
        Ravner.Accounts.ScopeResolver.can_scan_domain?(
          socket.assigns[:current_scope],
          socket.assigns[:domain]
        )

      val ->
        val
    end
  end

  def can_manage?(socket) do
    case socket.assigns[:can_manage?] do
      nil ->
        Ravner.Accounts.ScopeResolver.can_manage_domain?(
          socket.assigns[:current_scope],
          socket.assigns[:domain]
        )

      val ->
        val
    end
  end

  defp authorize_and_check_scannable(socket, fun) do
    domain = socket.assigns.domain

    cond do
      not can_scan?(socket) ->
        {:noreply,
         notify_flash(socket, :error, "You don't have permission to perform this action.")}

      not Domain.scannable?(domain) ->
        {:noreply,
         notify_flash(
           socket,
           :error,
           "Scanning is disabled for #{format_lifecycle(domain.lifecycle_state)} domains."
         )}

      true ->
        fun.(socket)
    end
  end

  defp format_lifecycle(state) when is_atom(state) do
    state |> Atom.to_string() |> String.replace("_", " ")
  end

  defp format_lifecycle(state), do: to_string(state)

  # ─── Discovery & Deep Scans ────────────────────────────────────────────────

  def handle_scan_all(socket) do
    authorize_and_check_scannable(socket, fn socket ->
      domain_id = socket.assigns.domain.id
      liveview_pid = self()
      user_id = socket.assigns.current_scope.user.id

      socket =
        socket
        |> assign(:scanning, true)
        |> assign(:active_scan_kind, :all)
        |> assign(:pending_scans, 4)
        |> assign(:scan_errors, [])

      start_scan_tasks(liveview_pid, domain_id, user_id)

      {:noreply, socket}
    end)
  end

  def handle_scan_all_subdomains(socket) do
    authorize_and_check_scannable(socket, fn socket ->
      domain = socket.assigns.domain

      case domain.subdomains do
        [] ->
          {:noreply, socket}

        subdomains ->
          subdomain_count = length(subdomains)
          user_id = socket.assigns.current_scope.user.id
          topic = "subdomain_scans:domain:#{domain.id}"

          subdomains
          |> Enum.map(
            &Ravner.Workers.ScanWorker.new(%{
              domain_id: &1.id,
              scan_type: "quick",
              notify_topic: topic,
              user_id: user_id
            })
          )
          |> Oban.insert_all()

          socket =
            socket
            |> assign(:scanning, true)
            |> assign(:active_scan_kind, :all_subdomains)
            |> assign(:pending_scans, subdomain_count)
            |> notify_flash(:info, "Queued quick scans for #{subdomain_count} subdomains.")

          {:noreply, socket}
      end
    end)
  end

  def handle_scan_subdomains(socket) do
    authorize_and_check_scannable(socket, fn socket ->
      domain_id = socket.assigns.domain.id
      liveview_pid = self()
      user_id = socket.assigns.current_scope.user.id

      socket =
        socket
        |> assign(:scanning, true)
        |> assign(:active_scan_kind, :subdomains)

      start_background_scan(user_id, fn ->
        result = Scans.run_subdomain_scan(domain_id)
        send(liveview_pid, {:scan_done, :subdomains, result})
      end)

      {:noreply, socket}
    end)
  end

  def handle_scan_httpx(socket) do
    authorize_and_check_scannable(socket, fn socket ->
      domain_id = socket.assigns.domain.id
      liveview_pid = self()
      user_id = socket.assigns.current_scope.user.id

      socket =
        socket
        |> assign(:scanning, true)
        |> assign(:active_scan_kind, :httpx)

      start_background_scan(user_id, fn ->
        result = Scans.Http.run_httpx_scan(domain_id)
        send(liveview_pid, {:scan_done, :httpx, result})
      end)

      {:noreply, socket}
    end)
  end

  def handle_scan_deep_tech(socket) do
    authorize_and_check_scannable(socket, fn socket ->
      domain_id = socket.assigns.domain.id
      liveview_pid = self()
      user_id = socket.assigns.current_scope.user.id

      socket =
        socket
        |> assign(:scanning, true)
        |> assign(:active_scan_kind, :deep_tech)

      start_background_scan(user_id, fn ->
        result = Scans.Http.run_deep_tech_scan(domain_id)
        send(liveview_pid, {:scan_done, :deep_tech, result})
      end)

      {:noreply, socket}
    end)
  end

  def handle_scan_dnsx(socket) do
    authorize_and_check_scannable(socket, fn socket ->
      domain_id = socket.assigns.domain.id
      liveview_pid = self()
      user_id = socket.assigns.current_scope.user.id

      socket =
        socket
        |> assign(:scanning, true)
        |> assign(:active_scan_kind, :dnsx)

      start_background_scan(user_id, fn ->
        result = Scans.Dns.run(domain_id)
        send(liveview_pid, {:scan_done, :dnsx, result})
      end)

      {:noreply, socket}
    end)
  end

  def handle_scan_rdap(socket) do
    authorize_and_check_scannable(socket, fn socket ->
      domain_id = socket.assigns.domain.id
      liveview_pid = self()
      user_id = socket.assigns.current_scope.user.id

      socket =
        socket
        |> assign(:scanning, true)
        |> assign(:active_scan_kind, :rdap)

      start_background_scan(user_id, fn ->
        result = Scans.Whois.run_rdap_scan(domain_id)
        send(liveview_pid, {:scan_done, :rdap, result})
      end)

      {:noreply, socket}
    end)
  end

  # ─── Accessibility & Lighthouse ────────────────────────────────────────────

  def handle_scan_a11y(socket) do
    authorize_and_check_scannable(socket, fn socket ->
      domain = socket.assigns.domain
      user_id = socket.assigns.current_scope.user.id

      if A11y.scannable?(domain) do
        %{domain_id: domain.id, user_id: user_id}
        |> Ravner.Workers.A11yScanWorker.new()
        |> Oban.insert()

        {:noreply,
         socket
         |> assign(:a11y_running?, true)
         |> notify_flash(:info, "Accessibility scan queued.")}
      else
        {:noreply, notify_flash(socket, :error, "Domain is not eligible for accessibility scan.")}
      end
    end)
  end

  def handle_scan_lighthouse(socket) do
    authorize_and_check_scannable(socket, fn socket ->
      domain = socket.assigns.domain
      user_id = socket.assigns.current_scope.user.id

      if Lighthouse.scannable?(domain) do
        %{domain_id: domain.id, user_id: user_id}
        |> Ravner.Workers.LighthouseScanWorker.new()
        |> Oban.insert()

        {:noreply,
         socket
         |> assign(:lighthouse_running?, true)
         |> notify_flash(:info, "Lighthouse scan queued.")}
      else
        {:noreply, notify_flash(socket, :error, "Domain is not eligible for Lighthouse scan.")}
      end
    end)
  end

  # ─── Scheduling Configuration ──────────────────────────────────────────────

  def handle_update_scheduling(socket, params, reload_fun) do
    if can_manage?(socket) do
      domain = socket.assigns.domain

      attrs = %{
        scan_interval_days: parse_interval(params["scan_interval_days"]),
        heartbeat_interval_minutes: parse_interval(params["heartbeat_interval_minutes"]),
        http_scan_interval_days: parse_interval(params["http_scan_interval_days"]),
        dns_scan_interval_days: parse_interval(params["dns_scan_interval_days"]),
        a11y_scan_interval_days: parse_interval(params["a11y_scan_interval_days"]),
        lighthouse_scan_interval_days: parse_interval(params["lighthouse_scan_interval_days"])
      }

      case Domains.upsert_domain_metadata(domain.id, attrs) do
        {:ok, _metadata} ->
          {:noreply,
           socket
           |> reload_fun.()
           |> notify_flash(:info, "Scheduling updated")}

        {:error, _changeset} ->
          {:noreply, notify_flash(socket, :error, "Failed to update scheduling")}
      end
    else
      {:noreply,
       notify_flash(socket, :error, "You don't have permission to perform this action.")}
    end
  end

  # ─── Info Message Handlers ─────────────────────────────────────────────────

  def handle_scan_done(socket, :subdomains, {:ok, results}, reload_fun) do
    {:noreply,
     socket
     |> reload_fun.()
     |> assign(:scan_results, results)
     |> complete_scan_step(
       :subdomains,
       {:info, "Found #{results.found} subdomains (#{results.new} new)"}
     )}
  end

  def handle_scan_done(socket, :httpx, {:ok, %{error: kind}}, reload_fun) do
    label = format_scan_error(kind)

    {:noreply,
     socket
     |> reload_fun.()
     |> complete_scan_step(:httpx, {:error, "HTTP scan error: #{label}"})}
  end

  def handle_scan_done(socket, :httpx, {:ok, _}, reload_fun) do
    {:noreply,
     socket
     |> reload_fun.()
     |> complete_scan_step(:httpx, {:info, "HTTP scan completed"})}
  end

  def handle_scan_done(socket, :deep_tech, {:ok, results}, reload_fun) do
    suffix =
      if results.errors == [] do
        ""
      else
        " (#{length(results.errors)} tool warnings)"
      end

    {:noreply,
     socket
     |> reload_fun.()
     |> complete_scan_step(
       :deep_tech,
       {:info,
        "Deep tech scan completed: #{results.evidence} findings, #{results.urls} URLs#{suffix}"}
     )}
  end

  def handle_scan_done(socket, :dnsx, {:ok, _}, reload_fun) do
    {:noreply,
     socket
     |> reload_fun.()
     |> complete_scan_step(:dnsx, {:info, "DNS scan completed"})}
  end

  def handle_scan_done(socket, :rdap, {:ok, %{source: source}}, reload_fun) do
    source_label =
      %{
        "rdap" => "RDAP",
        "whois" => "WHOIS",
        "ns_heuristics" => "NS heuristics",
        "none" => "no data found"
      }[source] || source

    {:noreply,
     socket
     |> reload_fun.()
     |> complete_scan_step(:rdap, {:info, "Registration scan completed via #{source_label}"})}
  end

  def handle_scan_done(socket, :subdomains, {:error, :external_redirect}, reload_fun) do
    {:noreply,
     socket
     |> reload_fun.()
     |> complete_scan_step(
       :subdomains,
       {:info, "Subdomain scan skipped — domain redirects externally"}
     )}
  end

  def handle_scan_done(socket, :subdomains, {:error, {:dns, _} = reason}, reload_fun) do
    Logger.info("Subdomain scan skipped: #{inspect(reason)}")

    {:noreply,
     socket
     |> reload_fun.()
     |> complete_scan_step(:subdomains, {:error, "Subdomains: #{format_scan_error(reason)}"})}
  end

  def handle_scan_done(socket, :subdomains, {:error, reason}, _reload_fun) do
    Logger.info("Subdomain scan returned no results: #{inspect(reason)}")

    {:noreply, complete_scan_step(socket, :subdomains, {:info, "No subdomains found"})}
  end

  def handle_scan_done(socket, :security_scan, {:ok, scan}, reload_fun) do
    summary = Map.get(scan, :summary) || "completed"

    {:noreply,
     socket
     |> reload_fun.()
     |> assign(:running_security_scan, nil)
     |> assign(:scanning, false)
     |> assign(:active_scan_kind, nil)
     |> put_flash(:info, "Security scan completed — #{summary}")}
  end

  def handle_scan_done(socket, :security_scan, {:error, reason}, _reload_fun) do
    {:noreply,
     socket
     |> assign(:scanning, false)
     |> assign(:running_security_scan, nil)
     |> assign(:active_scan_kind, nil)
     |> put_flash(:error, "Security scan failed: #{format_scan_error(reason)}")}
  end

  def handle_scan_done(socket, kind, {:error, reason}, reload_fun) do
    msg = "#{scan_kind_label(kind)} scan error: #{format_scan_error(reason)}"

    {:noreply,
     socket
     |> reload_fun.()
     |> complete_scan_step(kind, {:error, msg})}
  end

  def handle_scan_done(socket, kind, _result, reload_fun) do
    msg = "#{scan_kind_label(kind)} scan returned unexpected data."

    {:noreply,
     socket
     |> reload_fun.()
     |> complete_scan_step(kind, {:error, msg})}
  end

  def handle_a11y_completed(socket, %{status: "failed"} = scan) do
    {:noreply,
     socket
     |> assign(:a11y_running?, false)
     |> put_flash(:error, "Accessibility scan failed: #{scan.error_message || "unknown error"}")}
  end

  def handle_a11y_completed(socket, scan) do
    {:noreply,
     socket
     |> assign(:a11y_scan, scan)
     |> assign(:a11y_running?, false)
     |> put_flash(
       :info,
       "Accessibility scan completed (#{scan.violations_count || 0} violations)."
     )}
  end

  def handle_lighthouse_completed(socket, %{status: "failed"} = scan) do
    {:noreply,
     socket
     |> assign(:lighthouse_running?, false)
     |> put_flash(:error, "Lighthouse scan failed: #{scan.error_message || "unknown error"}")}
  end

  def handle_lighthouse_completed(socket, scan) do
    {:noreply,
     socket
     |> assign(:lighthouse_scan, scan)
     |> assign(:lighthouse_running?, false)
     |> put_flash(:info, "Lighthouse scan completed.")}
  end

  # ─── Worker & Task helpers ─────────────────────────────────────────────────

  def start_scan_tasks(pid, id, user_id) do
    start_background_scan(user_id, fn ->
      results = Scans.run_quick_scan(id)

      send(pid, {:scan_done, :dnsx, Map.fetch!(results, :dnsx)})
      send(pid, {:scan_done, :httpx, Map.fetch!(results, :httpx)})
      send(pid, {:scan_done, :rdap, Map.fetch!(results, :rdap)})
      send(pid, {:scan_done, :subdomains, Map.fetch!(results, :subdomains)})
    end)
  end

  def start_background_scan(user_id, fun) when is_function(fun, 0) do
    Task.Supervisor.start_child(Ravner.ScanTaskSupervisor, fn ->
      if user_id, do: Ravner.ActivityLog.set_user(user_id)
      fun.()
    end)
  end

  def finish_scan(socket) do
    case socket.assigns[:active_scan_kind] do
      kind when kind in [:all, :all_subdomains] ->
        pending = max(0, (socket.assigns[:pending_scans] || 1) - 1)

        if pending == 0 do
          socket
          |> assign(:scanning, false)
          |> assign(:active_scan_kind, nil)
          |> assign(:pending_scans, 0)
        else
          assign(socket, :pending_scans, pending)
        end

      _ ->
        socket
        |> assign(:scanning, false)
        |> assign(:active_scan_kind, nil)
    end
  end

  defp complete_scan_step(socket, kind, outcome) do
    if socket.assigns[:active_scan_kind] == :all do
      errors = socket.assigns[:scan_errors] || []

      errors =
        case outcome do
          {:error, msg} -> [{kind, msg} | errors]
          _ -> errors
        end

      socket =
        socket
        |> assign(:scan_errors, errors)
        |> finish_scan()

      if socket.assigns[:pending_scans] == 0 do
        emit_quick_scan_summary_flash(socket, Enum.reverse(errors))
      else
        socket
      end
    else
      socket = finish_scan(socket)

      case outcome do
        {:info, msg} -> put_flash(socket, :info, msg)
        {:error, msg} -> put_flash(socket, :error, msg)
      end
    end
  end

  defp emit_quick_scan_summary_flash(socket, []) do
    socket
    |> assign(:scan_errors, [])
    |> put_flash(:info, "All discovery scans completed.")
  end

  defp emit_quick_scan_summary_flash(socket, errors) do
    summary = Enum.map_join(errors, "; ", fn {_kind, msg} -> msg end)

    socket
    |> assign(:scan_errors, [])
    |> put_flash(:error, "Discovery scan completed with errors: #{summary}")
  end

  defp scan_kind_label(:dnsx), do: "DNS"
  defp scan_kind_label(:httpx), do: "HTTP"
  defp scan_kind_label(:rdap), do: "Registration"
  defp scan_kind_label(:subdomains), do: "Subdomains"
  defp scan_kind_label(:deep_tech), do: "Tech stack"
  defp scan_kind_label(other), do: to_string(other)

  defp format_scan_error(:nxdomain), do: "DNS resolution failed (NXDOMAIN)"
  defp format_scan_error(:timeout), do: "Connection timed out"
  defp format_scan_error(:servfail), do: "DNS server failure (SERVFAIL)"
  defp format_scan_error(:tls_error), do: "TLS/SSL error"
  defp format_scan_error(:connection_refused), do: "Connection refused"
  defp format_scan_error(:connection_closed), do: "Connection closed"
  defp format_scan_error(:connection_error), do: "Connection failed"
  defp format_scan_error(:no_ips), do: "No routable IP addresses found"
  defp format_scan_error(:external_redirect), do: "Domain redirects externally"
  defp format_scan_error({:dns, inner}), do: "Skipped (#{format_scan_error(inner)})"
  defp format_scan_error({:network, reason}), do: "Network error (#{inspect(reason)})"
  defp format_scan_error(reason) when is_binary(reason), do: reason

  defp format_scan_error(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp format_scan_error(reason), do: inspect(reason)

  defp parse_interval(nil), do: nil
  defp parse_interval(""), do: nil
  defp parse_interval(val) when is_binary(val), do: String.to_integer(val)
  defp parse_interval(val) when is_integer(val), do: val
end
