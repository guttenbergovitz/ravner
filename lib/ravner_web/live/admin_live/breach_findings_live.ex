defmodule RavnerWeb.AdminLive.BreachFindingsLive do
  @moduledoc """
  Admin UI LiveView for managing dark‑web breach findings.
  Allows viewing all findings and changing their status (resolved, false positive, etc.).
  """

  use RavnerWeb, :live_view
  alias Ravner.{Repo, BreachFinding, BreachFindingCtx}
  import Ecto.Query, only: [from: 2]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Breach Findings")
     |> assign(:findings, list_findings())}
  end

  @impl true
  def handle_event("set_status", %{"id" => id, "status" => status}, socket) do
    case BreachFindingCtx.set_status(String.to_integer(id), status) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:findings, list_findings())
         |> put_flash(:info, "Status updated to #{status}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update status")}
    end
  end

  defp list_findings do
    from(f in BreachFinding, order_by: [desc: f.inserted_at])
    |> Repo.all()
  end
end
