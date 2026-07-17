defmodule RavnerWeb.UptimeComponents do
  @moduledoc """
  SVG chart components for uptime monitoring visualizations.
  """
  use Phoenix.Component

  @doc """
  Renders a 30-day uptime bar — a horizontal strip of colored segments.

  ## Assigns
  - `days` - list of %{date: Date, percent: float}, ordered oldest to newest
  - `class` - optional additional CSS class
  """
  attr :days, :list, required: true
  attr :class, :string, default: ""

  def uptime_bar(assigns) do
    segment_width = 10
    gap = 2
    height = 28
    count = length(assigns.days)
    total_width = count * (segment_width + gap) - gap

    assigns =
      assigns
      |> assign(:segment_width, segment_width)
      |> assign(:gap, gap)
      |> assign(:height, height)
      |> assign(:total_width, total_width)
      |> assign(:indexed_days, Enum.with_index(assigns.days))

    ~H"""
    <svg
      viewBox={"0 0 #{@total_width} #{@height}"}
      class={["w-full max-w-md h-7", @class]}
      role="img"
      aria-label="30-day uptime history"
    >
      <rect
        :for={{day, i} <- @indexed_days}
        x={i * (@segment_width + @gap)}
        y="0"
        width={@segment_width}
        height={@height}
        rx="2"
        ry="2"
        fill={bar_color(day.percent)}
        opacity={bar_opacity(day.percent)}
      >
        <title>{Calendar.strftime(day.date, "%b %d")} — {if day.percent, do: "#{day.percent}%", else: "No data"}</title>
      </rect>
    </svg>
    """
  end

  defp bar_color(nil), do: "#d4d4d4"
  defp bar_color(percent) when percent >= 99.5, do: "#22c55e"
  defp bar_color(percent) when percent >= 98.0, do: "#4ade80"
  defp bar_color(percent) when percent >= 95.0, do: "#eab308"
  defp bar_color(percent) when percent >= 90.0, do: "#f97316"
  defp bar_color(_percent), do: "#ef4444"

  defp bar_opacity(nil), do: "0.4"
  defp bar_opacity(percent) when percent >= 99.5, do: "0.85"
  defp bar_opacity(percent) when percent >= 95.0, do: "0.9"
  defp bar_opacity(_percent), do: "0.9"

  @doc """
  Renders a response time line chart with gradient area fill.

  ## Assigns
  - `points` - list of %{at: DateTime, ms: integer}, ordered by time
  - `class` - optional CSS class
  - `height` - SVG height in px (default 160)
  """
  attr :points, :list, required: true
  attr :class, :string, default: ""
  attr :height, :integer, default: 160

  def response_chart(assigns) do
    width = 600
    padding_x = 40
    padding_y = 20
    chart_width = width - padding_x * 2
    chart_height = assigns.height - padding_y * 2

    points = assigns.points

    {path, area_path, y_labels, x_labels} =
      if points == [] do
        {"", "", [], []}
      else
        ms_values = Enum.map(points, & &1.ms)
        max_ms = max(Enum.max(ms_values), 1)
        min_ms = Enum.min(ms_values)
        range = max(max_ms - min_ms, 1)
        n = length(points)

        coords =
          points
          |> Enum.with_index()
          |> Enum.map(fn {point, i} ->
            x = padding_x + i / max(n - 1, 1) * chart_width
            y = padding_y + (1 - (point.ms - min_ms) / range) * chart_height
            {Float.round(x * 1.0, 1), Float.round(y * 1.0, 1)}
          end)

        line_path =
          coords
          |> Enum.with_index()
          |> Enum.map(fn {{x, y}, i} ->
            if i == 0, do: "M #{x} #{y}", else: "L #{x} #{y}"
          end)
          |> Enum.join(" ")

        {last_x, _} = List.last(coords)
        {first_x, _} = List.first(coords)
        bottom_y = Float.round((padding_y + chart_height) * 1.0, 1)

        area = "#{line_path} L #{last_x} #{bottom_y} L #{first_x} #{bottom_y} Z"

        y_labels =
          for frac <- [0.0, 0.33, 0.66, 1.0] do
            ms_val = round(min_ms + (max_ms - min_ms) * (1 - frac))
            y_pos = Float.round(padding_y + frac * chart_height, 1)
            %{ms: ms_val, y: y_pos}
          end

        x_labels =
          [List.first(points), Enum.at(points, div(n, 2)), List.last(points)]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(& &1.at)
          |> Enum.with_index()
          |> Enum.map(fn {point, i} ->
            x = Float.round((padding_x + i / max(2, 1) * chart_width) * 1.0, 1)
            %{label: Calendar.strftime(point.at, "%H:%M"), x: x}
          end)

        {line_path, area, y_labels, x_labels}
      end

    assigns =
      assigns
      |> assign(:width, width)
      |> assign(:padding_x, padding_x)
      |> assign(:padding_y, padding_y)
      |> assign(:chart_width, chart_width)
      |> assign(:chart_height, chart_height)
      |> assign(:path, path)
      |> assign(:area_path, area_path)
      |> assign(:y_labels, y_labels)
      |> assign(:x_labels, x_labels)

    ~H"""
    <svg
      viewBox={"0 0 #{@width} #{@height}"}
      class={["w-full", @class]}
      role="img"
      aria-label="Response time chart"
    >
      <defs>
        <linearGradient id="response-fill" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#22c55e" stop-opacity="0.15" />
          <stop offset="100%" stop-color="#22c55e" stop-opacity="0.02" />
        </linearGradient>
      </defs>

      <%!-- Grid lines --%>
      <line
        :for={label <- @y_labels}
        x1={@padding_x}
        y1={label.y}
        x2={@width - @padding_x}
        y2={label.y}
        stroke="currentColor"
        stroke-opacity="0.08"
        stroke-width="1"
      />

      <%!-- Y-axis labels --%>
      <text
        :for={label <- @y_labels}
        x={@padding_x - 6}
        y={label.y + 3}
        text-anchor="end"
        class="fill-neutral-400 dark:fill-neutral-500"
        font-size="9"
        font-family="inherit"
      >
        {label.ms}ms
      </text>

      <%!-- X-axis labels --%>
      <text
        :for={label <- @x_labels}
        x={label.x}
        y={@height - 4}
        text-anchor="middle"
        class="fill-neutral-400 dark:fill-neutral-500"
        font-size="9"
        font-family="inherit"
      >
        {label.label}
      </text>

      <%!-- Area fill --%>
      <%= if @area_path != "" do %>
        <path d={@area_path} fill="url(#response-fill)" />
      <% end %>

      <%!-- Line --%>
      <%= if @path != "" do %>
        <path
          d={@path}
          fill="none"
          stroke="#22c55e"
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      <% end %>
    </svg>
    """
  end

  @doc """
  Renders a monthly availability calendar with colored day cells.

  ## Assigns
  - `days` - list of %{date: Date, uptime_percent: float} for the month
  - `month` - Date representing the month (any day in that month)
  - `class` - optional CSS class
  - `on_click` - optional event name to fire when a day is clicked (sends %{"date" => iso_date})
  """
  attr :days, :list, required: true
  attr :month, :any, required: true
  attr :class, :string, default: ""
  attr :on_click, :string, default: nil

  def availability_calendar(assigns) do
    today = Date.utc_today()
    day_map = Map.new(assigns.days, fn d -> {d.date, d.uptime_percent} end)

    first = Date.beginning_of_month(assigns.month)
    last = Date.end_of_month(assigns.month)
    start_offset = Date.day_of_week(first) - 1

    all_days = Date.range(first, last) |> Enum.to_list()
    padded = List.duplicate(nil, start_offset) ++ all_days

    weeks =
      padded
      |> Enum.chunk_every(7, 7, List.duplicate(nil, 7))
      |> Enum.take(6)

    assigns =
      assigns
      |> assign(:weeks, weeks)
      |> assign(:day_map, day_map)
      |> assign(:today, today)
      |> assign(:month_name, Calendar.strftime(first, "%B %Y"))

    ~H"""
    <div class={["text-xs", @class]}>
      <p class="font-medium text-neutral-700 dark:text-neutral-300 mb-2">{@month_name}</p>
      <div class="grid grid-cols-7 gap-1">
        <span
          :for={day_name <- ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]}
          class="text-center text-[10px] text-neutral-400 font-medium pb-1"
        >
          {day_name}
        </span>
        <%= for week <- @weeks do %>
          <%= for day <- week do %>
            <%= cond do %>
              <% is_nil(day) -> %>
                <div></div>
              <% Date.compare(day, @today) == :gt -> %>
                <%!-- Future day: empty/muted --%>
                <div class="aspect-square rounded-sm flex items-center justify-center text-[9px] text-neutral-300 dark:text-neutral-700">
                  {day.day}
                </div>
              <% true -> %>
                <% pct = Map.get(@day_map, day) %>
                <div
                  class={[
                    "aspect-square rounded-sm flex items-center justify-center text-[9px] font-medium transition-colors",
                    calendar_cell_class(pct),
                    @on_click && "cursor-pointer hover:ring-2 hover:ring-neutral-300 dark:hover:ring-neutral-600"
                  ]}
                  title={calendar_title(day, pct)}
                  phx-click={@on_click}
                  phx-value-date={Date.to_iso8601(day)}
                >
                  {day.day}
                </div>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp calendar_title(day, nil), do: "#{Calendar.strftime(day, "%b %d")} — No data"
  defp calendar_title(day, pct), do: "#{Calendar.strftime(day, "%b %d")} — #{pct}%"

  # nil = no data collected
  defp calendar_cell_class(nil),
    do: "bg-neutral-50 text-neutral-400 dark:bg-neutral-800/50 dark:text-neutral-500"

  defp calendar_cell_class(percent) when percent >= 99.5,
    do: "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400"

  defp calendar_cell_class(percent) when percent >= 98.0,
    do: "bg-green-50 text-green-600 dark:bg-green-900/20 dark:text-green-500"

  defp calendar_cell_class(percent) when percent >= 95.0,
    do: "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400"

  defp calendar_cell_class(percent) when percent >= 90.0,
    do: "bg-orange-100 text-orange-700 dark:bg-orange-900/30 dark:text-orange-400"

  defp calendar_cell_class(_percent),
    do: "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"

  @doc """
  Renders a vertical bar chart showing downtime % per time unit.
  Bars grow downward from 100% line — taller bar = more downtime.

  ## Assigns
  - `data` - list of %{label: String, uptime_percent: float | nil}
  - `class` - optional CSS class
  """
  attr :data, :list, required: true
  attr :class, :string, default: ""

  def downtime_chart(assigns) do
    width = 720
    height = 220
    padding_x = 35
    padding_y = 25
    chart_width = width - padding_x * 2
    chart_height = height - padding_y * 2 - 15

    n = length(assigns.data)
    # Ensure all bars fit: n*bar + (n-1)*gap = chart_width
    bar_width = if n > 0, do: Float.round(chart_width * 0.65 / n, 1), else: 10
    gap = if n > 1, do: Float.round((chart_width - n * bar_width) / (n - 1), 1), else: 2

    bars =
      assigns.data
      |> Enum.with_index()
      |> Enum.map(fn {item, i} ->
        x = Float.round(padding_x + i * (bar_width + gap), 1)

        {bar_h, color, opacity, downtime_pct} =
          case item.uptime_percent do
            nil -> {0, "#d4d4d4", "0.3", nil}
            pct ->
              dt = Float.round(100.0 - pct, 2)
              h = Float.round(dt / 100 * chart_height, 1)
              {h, downtime_bar_color(pct), "0.85", dt}
          end

        %{
          x: x,
          bar_width: bar_width,
          bar_height: bar_h,
          y: Float.round((padding_y + chart_height - bar_h) * 1.0, 1),
          color: color,
          opacity: opacity,
          label: item.label,
          downtime_pct: downtime_pct,
          uptime_pct: item.uptime_percent
        }
      end)

    assigns =
      assigns
      |> assign(:width, width)
      |> assign(:height, height)
      |> assign(:padding_x, padding_x)
      |> assign(:padding_y, padding_y)
      |> assign(:chart_height, chart_height)
      |> assign(:bars, bars)

    ~H"""
    <svg
      viewBox={"0 0 #{@width} #{@height}"}
      class={["w-full", @class]}
      role="img"
      aria-label="Downtime bar chart"
    >
      <%!-- Y-axis title --%>
      <text
        x="10"
        y={@padding_y + @chart_height / 2}
        text-anchor="middle"
        transform={"rotate(-90, 10, #{@padding_y + @chart_height / 2})"}
        class="fill-neutral-400 dark:fill-neutral-500"
        font-size="9"
      >
        Downtime %
      </text>

      <%!-- Baseline (0% downtime = 100% uptime) --%>
      <line
        x1={@padding_x}
        y1={@padding_y + @chart_height}
        x2={@width - @padding_x}
        y2={@padding_y + @chart_height}
        stroke="currentColor"
        stroke-opacity="0.1"
        stroke-width="1"
      />

      <%!-- Grid lines at 1%, 5%, 10% downtime --%>
      <line
        :for={pct <- [1, 5, 10]}
        x1={@padding_x}
        y1={Float.round(@padding_y + @chart_height - pct / 100 * @chart_height, 1)}
        x2={@width - @padding_x}
        y2={Float.round(@padding_y + @chart_height - pct / 100 * @chart_height, 1)}
        stroke="currentColor"
        stroke-opacity="0.05"
        stroke-width="1"
        stroke-dasharray="4 4"
      />
      <text
        :for={pct <- [1, 5, 10]}
        x={@padding_x - 4}
        y={Float.round(@padding_y + @chart_height - pct / 100 * @chart_height + 3, 1)}
        text-anchor="end"
        class="fill-neutral-300 dark:fill-neutral-600"
        font-size="8"
      >
        {pct}%
      </text>

      <%!-- Bars --%>
      <rect
        :for={bar <- @bars}
        x={bar.x}
        y={bar.y}
        width={bar.bar_width}
        height={max(bar.bar_height, 0)}
        rx="2"
        fill={bar.color}
        opacity={bar.opacity}
      >
        <title>{bar.label}: {if bar.uptime_pct, do: "#{bar.uptime_pct}% uptime (#{bar.downtime_pct}% down)", else: "No data"}</title>
      </rect>

      <%!-- No-data indicator (small grey dot) --%>
      <circle
        :for={bar <- Enum.filter(@bars, &is_nil(&1.uptime_pct))}
        cx={Float.round(bar.x + bar.bar_width / 2, 1)}
        cy={@padding_y + @chart_height - 2}
        r="2"
        fill="#d4d4d4"
        opacity="0.5"
      />

      <%!-- X labels --%>
      <text
        :for={bar <- @bars}
        x={Float.round(bar.x + bar.bar_width / 2, 1)}
        y={@height - 2}
        text-anchor="middle"
        class="fill-neutral-400 dark:fill-neutral-500"
        font-size="8"
      >
        {bar.label}
      </text>
    </svg>
    """
  end

  defp downtime_bar_color(uptime) when uptime >= 99.5, do: "#22c55e"
  defp downtime_bar_color(uptime) when uptime >= 98.0, do: "#4ade80"
  defp downtime_bar_color(uptime) when uptime >= 95.0, do: "#eab308"
  defp downtime_bar_color(uptime) when uptime >= 90.0, do: "#f97316"
  defp downtime_bar_color(_uptime), do: "#ef4444"
end
