defmodule RavnerWeb.DomainLive.ScanSchedule do
  @moduledoc "Scheduling controls for domain scans and uptime monitoring."

  use RavnerWeb, :html
  import RavnerWeb.DomainLive.ScanScheduleCore
  import RavnerWeb.DomainLive.ScanScheduleQuality

  attr :domain, :map, required: true
  attr :can_manage?, :boolean, required: true
  attr :myself, :any, required: true

  def scan_schedule(assigns) do
    ~H"""
    <div class="card-line" id="scheduling-panel">
      <h2 class="text-sm font-normal tracking-wide uppercase mb-6">
        Scheduling & Automation
      </h2>

      <form phx-submit="update_scheduling" phx-target={@myself} class="space-y-4 text-sm font-light">
        <.scan_schedule_core domain={@domain} can_manage?={@can_manage?} />
        <.scan_schedule_quality domain={@domain} can_manage?={@can_manage?} />
      </form>

      <%!-- Uptime monitoring link --%>
      <%= if @domain.domain_metadata && @domain.domain_metadata.heartbeat_interval_minutes do %>
        <div class="mt-4 pt-4 border-t border-neutral-100 dark:border-neutral-800">
          <.link
            navigate={~p"/uptime/#{@domain.id}"}
            class="flex items-center gap-2 text-xs text-neutral-500 hover:text-neutral-700 transition-colors dark:hover:text-neutral-300"
          >
            <.icon name="hero-chart-bar" class="w-3.5 h-3.5" /> View uptime monitoring detail
          </.link>
        </div>
      <% end %>
    </div>
    """
  end
end
