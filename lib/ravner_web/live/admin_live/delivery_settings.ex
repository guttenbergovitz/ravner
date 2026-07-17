defmodule RavnerWeb.AdminLive.DeliverySettings do
  use RavnerWeb, :live_view

  alias Ravner.DeliverySettings

  @impl true
  def mount(_params, _session, socket) do
    settings = DeliverySettings.get_all()

    {:ok,
     socket
     |> assign(:page_title, "Delivery Settings")
     |> assign(:settings, settings)
     |> assign(:active_tab, :email)
     |> assign(:test_result, nil)}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab)) |> assign(:test_result, nil)}
  end

  @impl true
  def handle_event("save_email", params, socket) do
    provider = params["provider"]
    DeliverySettings.set("email_provider", provider)
    DeliverySettings.set("email_from_name", params["from_name"])
    DeliverySettings.set("email_from_address", params["from_address"])

    # Save provider-specific fields
    fields = get_in(DeliverySettings.email_providers(), [provider, :fields]) || []
    for field <- fields do
      value = params[field] || ""
      secret? = String.contains?(field, "password") || String.contains?(field, "secret") || String.contains?(field, "api_key") || String.contains?(field, "token")
      if value != "", do: DeliverySettings.set("email_#{field}", value, secret: secret?)
    end

    {:noreply,
     socket
     |> assign(:settings, DeliverySettings.get_all())
     |> put_flash(:info, "Email settings saved.")}
  end

  @impl true
  def handle_event("save_sms", params, socket) do
    provider = params["provider"]
    DeliverySettings.set("sms_provider", provider)

    fields = get_in(DeliverySettings.sms_providers(), [provider, :fields]) || []
    for field <- fields do
      value = params[field] || ""
      secret? = String.contains?(field, "secret") || String.contains?(field, "api_key") || String.contains?(field, "token")
      if value != "", do: DeliverySettings.set("sms_#{field}", value, secret: secret?)
    end

    {:noreply,
     socket
     |> assign(:settings, DeliverySettings.get_all())
     |> put_flash(:info, "SMS settings saved.")}
  end

  @impl true
  def handle_event("test_email", %{"to" => to}, socket) do
    if to == "" do
      {:noreply, put_flash(socket, :error, "Enter a recipient email.")}
    else
      result = send_test_email(to)
      {:noreply, assign(socket, :test_result, result)}
    end
  end

  @impl true
  def handle_event("test_sms", %{"to" => to}, socket) do
    if to == "" do
      {:noreply, put_flash(socket, :error, "Enter a phone number.")}
    else
      result = send_test_sms(to)
      {:noreply, assign(socket, :test_result, result)}
    end
  end

  defp send_test_email(to) do
    try do
      import Swoosh.Email

      from_name = DeliverySettings.email_from_name()
      from_addr = DeliverySettings.email_from_address()

      email =
        new()
        |> to(to)
        |> from({from_name, from_addr})
        |> subject("[Ravner] Test email — delivery settings")
        |> text_body("This is a test email from Ravner to verify your delivery configuration.\n\nIf you received this, email delivery is working correctly.\n\n— Ravner")

      case Ravner.Mailer.deliver(email) do
        {:ok, _} -> {:ok, "Test email sent to #{to}"}
        {:error, reason} -> {:error, "Failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, "Error: #{Exception.message(e)}"}
    end
  end

  defp send_test_sms(to) do
    try do
      body = "[Ravner] Test SMS — delivery is working. #{DateTime.utc_now() |> Calendar.strftime("%H:%M UTC")}"

      case Ravner.Uptime.SmsAdapter.send_sms(to, body) do
        {:ok, ref} -> {:ok, "Test SMS sent to #{to} (ref: #{ref})"}
        {:error, reason} -> {:error, "Failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, "Error: #{Exception.message(e)}"}
    end
  end
end
