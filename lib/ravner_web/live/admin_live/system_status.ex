defmodule RavnerWeb.AdminLive.SystemStatus do
  use RavnerWeb, :live_view

  alias Ravner.Mailer

  @external_tools ~w(dnsx httpx naabu nuclei katana webanalyze whois)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "System Status")
     |> assign(:checks, run_checks())
     |> assign(:test_email_sent, nil)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :checks, run_checks())}
  end

  @impl true
  def handle_event("send_test_email", _params, socket) do
    recipient = socket.assigns.current_scope.user.email

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(recipient)
      |> Swoosh.Email.from({"Ravner", mail_from()})
      |> Swoosh.Email.subject("Ravner test email")
      |> Swoosh.Email.text_body("This is a test email sent from Ravner system status page at #{DateTime.utc_now()}.")

    case Mailer.deliver(email) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:test_email_sent, :ok)
         |> put_flash(:info, "Test email sent to #{recipient}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:test_email_sent, :error)
         |> put_flash(:error, "Failed to send: #{inspect(reason)}")}
    end
  end

  defp run_checks do
    %{
      mailer: check_mailer(),
      database: check_database(),
      oban: check_oban(),
      tools: check_tools()
    }
  end

  defp check_mailer do
    config = Application.get_env(:ravner, Ravner.Mailer, [])
    adapter = Keyword.get(config, :adapter)

    %{
      adapter: adapter && adapter |> Module.split() |> List.last(),
      relay: Keyword.get(config, :relay),
      port: Keyword.get(config, :port),
      mail_from: mail_from(),
      configured?: adapter != nil
    }
  end

  defp check_database do
    try do
      Ravner.Repo.query!("SELECT 1")
      %{status: :ok}
    rescue
      e -> %{status: :error, message: Exception.message(e)}
    end
  end

  defp check_oban do
    try do
      %Oban.Config{} = Oban.config()
      %{status: :ok}
    rescue
      _ -> %{status: :error}
    end
  end

  defp check_tools do
    Enum.map(@external_tools, fn tool ->
      {tool, System.find_executable(tool) != nil}
    end)
  end

  defp mail_from do
    Application.get_env(:ravner, :mail_from, "noreply@example.com")
  end
end
