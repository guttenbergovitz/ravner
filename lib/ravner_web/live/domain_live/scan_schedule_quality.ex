defmodule RavnerWeb.DomainLive.ScanScheduleQuality do
  @moduledoc "Scheduling form fields."

  use RavnerWeb, :html

  attr :domain, :map, required: true
  attr :can_manage?, :boolean, required: true

  def scan_schedule_quality(assigns) do
    ~H"""
    <div>
      <label class="block text-xs font-light tracking-wide uppercase text-neutral-500 mb-1">
        A11y Scan
      </label>
      <select
        name="a11y_scan_interval_days"
        class="w-full text-xs font-light border-neutral-200 rounded-md focus:border-neutral-900 focus:ring-0"
        disabled={!@can_manage?}
      >
        <option
          value=""
          selected={
            is_nil(@domain.domain_metadata && @domain.domain_metadata.a11y_scan_interval_days)
          }
        >
          Manual only
        </option>
        <option
          value="7"
          selected={
            @domain.domain_metadata &&
              @domain.domain_metadata.a11y_scan_interval_days == 7
          }
        >
          Weekly
        </option>
        <option
          value="30"
          selected={
            @domain.domain_metadata &&
              @domain.domain_metadata.a11y_scan_interval_days == 30
          }
        >
          Monthly
        </option>
      </select>
    </div>

    <div>
      <label class="block text-xs font-light tracking-wide uppercase text-neutral-500 mb-1">
        Lighthouse
      </label>
      <select
        name="lighthouse_scan_interval_days"
        class="w-full text-xs font-light border-neutral-200 rounded-md focus:border-neutral-900 focus:ring-0"
        disabled={!@can_manage?}
      >
        <option
          value=""
          selected={
            is_nil(
              @domain.domain_metadata &&
                @domain.domain_metadata.lighthouse_scan_interval_days
            )
          }
        >
          Manual only
        </option>
        <option
          value="7"
          selected={
            @domain.domain_metadata &&
              @domain.domain_metadata.lighthouse_scan_interval_days == 7
          }
        >
          Weekly
        </option>
        <option
          value="30"
          selected={
            @domain.domain_metadata &&
              @domain.domain_metadata.lighthouse_scan_interval_days == 30
          }
        >
          Monthly
        </option>
      </select>
    </div>

    <p class="text-[10px] text-neutral-400 mt-2">
      Background jobs are queued automatically by Oban dispatchers based on the selected intervals.
    </p>

    <%= if @can_manage? do %>
      <button
        type="submit"
        class="mt-4 w-full btn-line justify-center text-xs"
      >
        Save Scheduling
      </button>
    <% end %>
    """
  end
end
