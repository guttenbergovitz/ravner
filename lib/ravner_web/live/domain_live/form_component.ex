defmodule RavnerWeb.DomainLive.FormComponent do
  use RavnerWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Ravner.Domains

  @impl true
  def update(%{domain: domain} = assigns, socket) do
    changeset = Domains.change_domain(domain)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate", %{"domain" => domain_params}, socket) do
    changeset =
      socket.assigns.domain
      |> Domains.change_domain(domain_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"domain" => domain_params}, socket) do
    save_domain(socket, socket.assigns.action, domain_params)
  end

  defp save_domain(socket, :new, domain_params) do
    case Domains.create_domain(domain_params) do
      {:ok, _domain} ->
        {:noreply,
         socket
         |> put_flash(:info, "Domain created successfully")
         |> push_navigate(to: ~p"/domains")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end
end
