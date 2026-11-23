defmodule RavnerWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for Ravner.
  """
  use Phoenix.Component
  use Gettext, backend: RavnerWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.
  """
  attr(:id, :string, doc: "the optional id of flash container")
  attr(:flash, :map, default: %{}, doc: "the map of flash messages to display")
  attr(:title, :string, default: nil)
  attr(:kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup")
  attr(:rest, :global, doc: "the arbitrary HTML attributes to add to the flash container")

  slot(:inner_block, doc: "the optional inner block that renders the flash message")

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast-line"
      {@rest}
    >
      <div class={[
        "alert-line flex items-start gap-3",
        @kind == :info && "alert-line-info",
        @kind == :error && "alert-line-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="w-5 h-5 shrink-0 mt-0.5" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="w-5 h-5 shrink-0 mt-0.5" />
        <div class="flex-1">
          <p :if={@title} class="font-normal mb-1">{@title}</p>
          <p class="text-neutral-600 dark:text-neutral-300">{msg}</p>
        </div>
        <button
          type="button"
          class="shrink-0 text-neutral-400 hover:text-neutral-600 transition-colors"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.
  """
  attr(:rest, :global, include: ~w(href navigate patch method download name value disabled))
  attr(:class, :any)
  attr(:variant, :string, values: ~w(primary))
  slot(:inner_block, required: true)

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => "btn-line-filled",
      nil => "btn-line"
    }

    assigns =
      assign_new(assigns, :class, fn ->
        Map.fetch!(variants, assigns[:variant])
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.
  """
  attr(:id, :any, default: nil)
  attr(:name, :any)
  attr(:label, :string, default: nil)
  attr(:value, :any)

  attr(:type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)
  )

  attr(:field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"
  )

  attr(:errors, :list, default: [])
  attr(:checked, :boolean, doc: "the checked flag for checkbox inputs")
  attr(:prompt, :string, default: nil, doc: "the prompt for select inputs")
  attr(:options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2")
  attr(:multiple, :boolean, default: false, doc: "the multiple flag for select inputs")
  attr(:class, :any, default: nil, doc: "the input class to use over defaults")
  attr(:error_class, :any, default: nil, doc: "the input error class to use over defaults")

  attr(:rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)
  )

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-4">
      <label class="flex items-center gap-3 cursor-pointer">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="checkbox-line"
          {@rest}
        />
        <span :if={@label} class="text-sm text-neutral-700 dark:text-neutral-300">
          {@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-4">
      <label>
        <span
          :if={@label}
          class="block text-xs font-light tracking-wide uppercase text-neutral-500 dark:text-neutral-400 mb-2"
        >
          {@label}
        </span>
        <select
          id={@id}
          name={@name}
          class={[
            "w-full px-0 py-3 border-0 border-b border-neutral-300 bg-transparent text-neutral-900 focus:outline-none focus:border-neutral-900 focus-visible:ring-2 focus-visible:ring-neutral-900/10 transition-colors text-sm dark:border-neutral-600 dark:text-neutral-100 dark:focus:border-neutral-300",
            @errors != [] && "border-red-300"
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="" class="text-neutral-400">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-4">
      <label>
        <span
          :if={@label}
          class="block text-xs font-light tracking-wide uppercase text-neutral-500 dark:text-neutral-400 mb-2"
        >
          {@label}
        </span>
        <textarea
          id={@id}
          name={@name}
          class={[
            "w-full px-0 py-3 border-0 border-b border-neutral-300 bg-transparent text-neutral-900 focus:outline-none focus:border-neutral-900 focus-visible:ring-2 focus-visible:ring-neutral-900/10 transition-colors text-sm resize-none dark:border-neutral-600 dark:text-neutral-100 dark:focus:border-neutral-300",
            @errors != [] && "border-red-300"
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="mb-4">
      <label>
        <span
          :if={@label}
          class="block text-xs font-light tracking-wide uppercase text-neutral-500 dark:text-neutral-400 mb-2"
        >
          {@label}
        </span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            "w-full px-0 py-3 border-0 border-b border-neutral-300 bg-transparent text-neutral-900 placeholder-neutral-400 focus:outline-none focus:border-neutral-900 focus-visible:ring-2 focus-visible:ring-neutral-900/10 transition-colors text-sm dark:border-neutral-600 dark:text-neutral-100 dark:placeholder-neutral-500 dark:focus:border-neutral-300",
            @errors != [] && "border-red-300"
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def error(assigns) do
    ~H"""
    <p class="mt-2 flex gap-2 items-center text-sm text-red-600 dark:text-red-400">
      <.icon name="hero-exclamation-circle" class="w-4 h-4 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot(:inner_block, required: true)
  slot(:subtitle)
  slot(:actions)

  def header(assigns) do
    ~H"""
    <header class={[
      @actions != [] && "flex items-center justify-between gap-6",
      "pb-6 mb-6 border-b border-neutral-100 dark:border-neutral-800"
    ]}>
      <div>
        <h1 class="text-xl font-light tracking-tight">
          {render_slot(@inner_block)}
        </h1>
        <p
          :if={@subtitle != []}
          class="text-sm text-neutral-500 dark:text-neutral-400 mt-1"
        >
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.
  """
  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, default: nil, doc: "the function for generating the row id")
  attr(:row_click, :any, default: nil, doc: "the function for handling phx-click on each row")

  attr(:row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"
  )

  slot :col, required: true do
    attr(:label, :string)
  end

  slot(:action, doc: "the slot for showing user actions in the last table column")

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table-line">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={[@row_click && "cursor-pointer"]}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.
  """
  slot :item, required: true do
    attr(:title, :string, required: true)
  end

  def list(assigns) do
    ~H"""
    <ul class="list-line">
      <li :for={item <- @item} class="list-line-item">
        <div>
          <div class="text-xs font-light tracking-wide uppercase text-neutral-500 dark:text-neutral-400 mb-1">
            {item.title}
          </div>
          <div class="text-sm">{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).
  """
  attr(:name, :string, required: true)
  attr(:class, :any, default: "w-4 h-4")

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders a card title/header.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def card_header(assigns) do
    ~H"""
    <h2 class={["card-title", @class]}>
      {render_slot(@inner_block)}
    </h2>
    """
  end

  @doc """
  Renders a collapsible facet/section header.
  """
  attr :title, :string, required: true
  attr :group, :string, required: true
  attr :expanded, :boolean, default: false

  def facet_header(assigns) do
    ~H"""
    <button
      phx-click="toggle_facet_group"
      phx-value-group={@group}
      class="w-full flex items-center justify-between text-[10px] font-normal uppercase tracking-widest text-neutral-400 mb-2 border-b border-neutral-100 pb-2 hover:text-neutral-900 transition-colors group dark:text-neutral-500 dark:border-neutral-800 dark:hover:text-neutral-100"
    >
      <span>{@title}</span>
      <.icon
        name={if @expanded, do: "hero-chevron-up", else: "hero-chevron-down"}
        class="w-3 h-3 opacity-50 group-hover:opacity-100"
      />
    </button>
    """
  end

  @doc """
  Renders a status indicator with colored dot.
  """
  attr :color, :atom,
    values: [:green, :yellow, :orange, :red, :neutral, :sky, :indigo],
    default: :neutral

  attr :class, :any, default: nil
  slot :inner_block, required: true

  def status_indicator(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5 font-light", status_text_class(@color), @class]}>
      <span class={["w-1.5 h-1.5 rounded-full shrink-0", status_dot_bg(@color)]}></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp status_text_class(:green), do: "text-green-700 dark:text-green-400"
  defp status_text_class(:yellow), do: "text-yellow-600 dark:text-yellow-400"
  defp status_text_class(:orange), do: "text-orange-700 dark:text-orange-400"
  defp status_text_class(:red), do: "text-red-700 dark:text-red-400"
  defp status_text_class(:sky), do: "text-sky-700 dark:text-sky-400"
  defp status_text_class(:indigo), do: "text-indigo-700 dark:text-indigo-400"
  defp status_text_class(_), do: "text-neutral-500 dark:text-neutral-400"

  defp status_dot_bg(:green), do: "bg-green-500"
  defp status_dot_bg(:yellow), do: "bg-yellow-400"
  defp status_dot_bg(:orange), do: "bg-orange-500"
  defp status_dot_bg(:red), do: "bg-red-500"
  defp status_dot_bg(:sky), do: "bg-sky-500"
  defp status_dot_bg(:indigo), do: "bg-indigo-500"
  defp status_dot_bg(_), do: "bg-neutral-400"

  @doc """
  Renders a compact inline badge.
  """
  attr :class, :any, default: nil
  attr :severity, :atom, values: [:critical, :high, :medium, :low, :info, nil], default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1.5 text-[9px] uppercase tracking-tighter transition-colors px-1.5 py-0.5 border",
        severity_badge_class(@severity),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp severity_badge_class(:critical),
    do:
      "bg-red-50 text-red-700 border-red-200 dark:bg-red-950/60 dark:text-red-300 dark:border-red-800"

  defp severity_badge_class(:high),
    do:
      "bg-orange-50 text-orange-700 border-orange-200 dark:bg-orange-950/60 dark:text-orange-300 dark:border-orange-800"

  defp severity_badge_class(:medium),
    do:
      "bg-yellow-50 text-yellow-700 border-yellow-200 dark:bg-yellow-950/60 dark:text-yellow-300 dark:border-yellow-800"

  defp severity_badge_class(:low),
    do:
      "bg-blue-50 text-blue-700 border-blue-200 dark:bg-blue-950/60 dark:text-blue-300 dark:border-blue-800"

  defp severity_badge_class(:info),
    do:
      "bg-neutral-50 text-neutral-600 border-neutral-200 dark:bg-neutral-800 dark:text-neutral-300 dark:border-neutral-700"

  defp severity_badge_class(_), do: nil

  @doc """
  Renders a status pill with dot indicator.
  """
  attr :status, :atom,
    values: [:operational, :down, :degraded, :disabled, :unknown],
    default: :unknown

  attr :label, :string, default: nil
  attr :class, :any, default: nil

  def status_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full",
      status_pill_class(@status),
      @class
    ]}>
      <span class={["w-1.5 h-1.5 rounded-full", status_dot_class(@status)]}></span>
      {@label || status_label(@status)}
    </span>
    """
  end

  defp status_pill_class(:operational),
    do: "bg-green-50 text-green-700 dark:bg-green-900/20 dark:text-green-400"

  defp status_pill_class(:down), do: "bg-red-50 text-red-700 dark:bg-red-900/20 dark:text-red-400"

  defp status_pill_class(:degraded),
    do: "bg-yellow-50 text-yellow-700 dark:bg-yellow-900/20 dark:text-yellow-400"

  defp status_pill_class(:disabled),
    do: "bg-neutral-100 text-neutral-500 dark:bg-neutral-800 dark:text-neutral-400"

  defp status_pill_class(_),
    do: "bg-neutral-100 text-neutral-500 dark:bg-neutral-800 dark:text-neutral-400"

  defp status_dot_class(:operational), do: "bg-green-500"
  defp status_dot_class(:down), do: "bg-red-500"
  defp status_dot_class(:degraded), do: "bg-yellow-500"
  defp status_dot_class(:disabled), do: "bg-neutral-400"
  defp status_dot_class(_), do: "bg-neutral-400"

  defp status_label(:operational), do: "Operational"
  defp status_label(:down), do: "Down"
  defp status_label(:degraded), do: "Degraded"
  defp status_label(:disabled), do: "Disabled"
  defp status_label(_), do: "Unknown"

  @doc """
  Renders a form label with consistent styling.
  """
  attr :for, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def form_label(assigns) do
    ~H"""
    <label
      for={@for}
      class={[
        "block text-xs font-light text-neutral-500 uppercase tracking-wide mb-1 dark:text-neutral-400",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc """
  Renders a toggle badge button for filters.
  """
  attr :active, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(phx-click aria-pressed title)
  slot :inner_block, required: true

  def toggle_badge(assigns) do
    ~H"""
    <button
      class={[
        "inline-flex items-center gap-1.5 text-[9px] uppercase tracking-tighter transition-colors px-1.5 py-0.5 border",
        @active &&
          "bg-neutral-900 text-white border-neutral-900 dark:bg-neutral-100 dark:text-neutral-900 dark:border-neutral-100",
        !@active &&
          "text-neutral-400 border-neutral-200 hover:border-neutral-400 dark:text-neutral-500 dark:border-neutral-700 dark:hover:border-neutral-500",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Renders a tab button for navigation.
  """
  attr :active, :boolean, default: false
  attr :count, :integer, default: nil
  attr :variant, :atom, values: [:minimal, :compact], default: :minimal
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(phx-click phx-value-tab id)
  slot :inner_block, required: true

  def tab_button(%{variant: :compact} = assigns) do
    ~H"""
    <button
      class={[
        "px-3 py-2.5 font-medium border-b-2 transition-colors inline-flex items-center gap-1.5 whitespace-nowrap",
        @active &&
          "border-neutral-900 text-neutral-900 font-semibold dark:border-neutral-100 dark:text-neutral-100",
        !@active &&
          "border-transparent text-neutral-500 hover:text-neutral-800 hover:border-neutral-300 dark:text-neutral-400 dark:hover:text-neutral-200",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
      <%= if @count && @count > 0 do %>
        <span class={[
          "text-[10px] px-1.5 py-0.5 rounded-full",
          @active && "bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900",
          !@active && "bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-300"
        ]}>
          {@count}
        </span>
      <% end %>
    </button>
    """
  end

  def tab_button(assigns) do
    ~H"""
    <button
      class={[
        "text-xs font-normal uppercase tracking-widest pb-4 border-b-2 transition-all duration-200",
        @active &&
          "border-neutral-900 text-neutral-900 font-medium dark:text-neutral-100 dark:border-neutral-100",
        !@active &&
          "border-transparent text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300", "opacity-0 translate-y-4",
         "opacity-100 translate-y-0"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0",
         "opacity-0 translate-y-4"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(RavnerWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(RavnerWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
