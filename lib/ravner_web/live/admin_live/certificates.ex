defmodule RavnerWeb.AdminLive.Certificates do
  @moduledoc """
  LiveView for administrative SSL certificate overview.
  """
  use RavnerWeb, :live_view

  alias Ravner.Repo
  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainMetadata
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    if admin?(socket.assigns.current_scope) do
      {:ok,
       socket
       |> assign(:page_title, "SSL Certificates")
       |> fetch_certificates()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Admin access required")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp fetch_certificates(socket) do
    query =
      from(m in DomainMetadata,
        join: d in Domain,
        on: m.domain_id == d.id,
        where: not is_nil(m.ssl_valid_until),
        order_by: [asc: m.ssl_valid_until],
        select: %{
          id: d.id,
          name: d.name,
          issuer: m.ssl_issuer,
          valid_from: m.ssl_valid_from,
          valid_until: m.ssl_valid_until,
          days_remaining: m.ssl_days_remaining
        }
      )

    certs = Repo.all(query)
    assign(socket, :certificates, certs)
  end

  defp admin?(nil), do: false
  defp admin?(scope), do: scope.user && scope.user.role == :admin
end
