defmodule RavnerWeb.DomainLive.ScanScheduleCore do
  @moduledoc "Scheduling form fields."

  use RavnerWeb, :html

  attr :domain, :map, required: true
  attr :can_manage?, :boolean, required: true

  def scan_schedule_core(assigns) do
    ~H"""
    <div>
      <label class="block text-xs font-light tracking-wide uppercase text-neutral-500 mb-1">
        Uptime Heartbeat
      </label>
      <select
        name="heartbeat_interval_minutes"
        class="w-full text-xs font-light border-neutral-200 rounded-md focus:border-neutral-900 focus:ring-0"
        disabled={!@can_manage?}
      >
        <option
          value=""
          selected={
            is_nil(
              @domain.domain_metadata &&
                @domain.domain_metadata.heartbeat_interval_minutes
            )
          }
        >
          Disabled
        </option>
        <option
          value="1"
          selected={
            @domain.domain_metadata &&
              @domain.domain_metadata.heartbeat_interval_minutes == 1
          }
        >
          Every minute
        </option>
        <option
          value="3"
          selected={
            @domain.domain_metadata &&
              @domain.domain_metadata.heartbeat_interval_minutes == 3
          }
        >
          Every 3 minutes
        </option>
        <option
          value="5"
          selected={
            @domain.domain_metadata &&
              @domain.domain_metadata.heartbeat_interval_minutes == 5
          }
        >
          Every 5 minutes
        </option>
        <option
          value="15"
          selected={
            @domain.domain_metadata &&
              @domain.domain_metadata.heartbeat_interval_minutes == 15
          }
        >
          Every 15 minutes
        </option>
        <option
          value="60"
          selected={
            @domain.domain_metadata &&
              @domain.domain_metadata.heartbeat_interval_minutes == 60
          }
        >
          Hourly
        </option>
      </select>
    </div>

    <div>
      <label class="block text-xs font-light tracking-wide uppercase text-neutral-500 mb-1">
        Security Scan
      </label>
      <select
        name="scan_interval_days"
        class="w-full text-xs font-light border-neutral-200 rounded-md focus:border-neutral-900 focus:ring-0"
        disabled={!@can_manage?}
      >
        <option
          value=""
          selected={is_nil(@domain.domain_metadata && @domain.domain_metadata.scan_interval_days)}
        >
          Manual only
        </option>
        <option
          value="1"
          selected={@domain.domain_metadata && @domain.domain_metadata.scan_interval_days == 1}
        >
          Daily
        </option>
        <option
          value="7"
          selected={@domain.domain_metadata && @domain.domain_metadata.scan_interval_days == 7}
        >
          Weekly
        </option>
        <option
          value="30"
          selected={@domain.domain_metadata && @domain.domain_metadata.scan_interval_days == 30}
        >
          Monthly
        </option>
      </select>
    </div>

    <div class="grid grid-cols-2 gap-4">
      <div>
        <label class="block text-xs font-light tracking-wide uppercase text-neutral-500 mb-1">
          HTTP Scan
        </label>
        <select
          name="http_scan_interval_days"
          class="w-full text-xs font-light border-neutral-200 rounded-md focus:border-neutral-900 focus:ring-0"
          disabled={!@can_manage?}
        >
          <option
            value=""
            selected={
              is_nil(@domain.domain_metadata && @domain.domain_metadata.http_scan_interval_days)
            }
          >
            Manual only
          </option>
          <option
            value="1"
            selected={
              @domain.domain_metadata &&
                @domain.domain_metadata.http_scan_interval_days == 1
            }
          >
            Daily
          </option>
          <option
            value="7"
            selected={
              @domain.domain_metadata &&
                @domain.domain_metadata.http_scan_interval_days == 7
            }
          >
            Weekly
          </option>
        </select>
      </div>
      <div>
        <label class="block text-xs font-light tracking-wide uppercase text-neutral-500 mb-1">
          DNS Scan
        </label>
        <select
          name="dns_scan_interval_days"
          class="w-full text-xs font-light border-neutral-200 rounded-md focus:border-neutral-900 focus:ring-0"
          disabled={!@can_manage?}
        >
          <option
            value=""
            selected={
              is_nil(@domain.domain_metadata && @domain.domain_metadata.dns_scan_interval_days)
            }
          >
            Manual only
          </option>
          <option
            value="1"
            selected={
              @domain.domain_metadata &&
                @domain.domain_metadata.dns_scan_interval_days == 1
            }
          >
            Daily
          </option>
          <option
            value="7"
            selected={
              @domain.domain_metadata &&
                @domain.domain_metadata.dns_scan_interval_days == 7
            }
          >
            Weekly
          </option>
        </select>
      </div>
    </div>
    """
  end
end
