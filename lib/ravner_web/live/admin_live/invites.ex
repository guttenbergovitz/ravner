defmodule RavnerWeb.AdminLive.Invites do
  use RavnerWeb, :live_view

  alias Ravner.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:invites, Accounts.list_invites())
     |> assign(:page_title, "Invites")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    form = to_form(%{"email" => "", "name" => "", "role" => "viewer"}, as: :invite)
    socket |> assign(:form, form)
  end

  @impl true
  def handle_event("validate", %{"invite" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :invite))}
  end

  def handle_event("send_invite", %{"invite" => params}, socket) do
    actor = socket.assigns.current_scope.user
    invited_by_id = actor.id

    case Accounts.create_invite(params, invited_by_id, actor: actor) do
      {:ok, invite} ->
        invite_url = url(~p"/users/invite/#{invite.token}")

        {:noreply,
         socket
         |> put_flash(:info, "Invite created. Share this link: #{invite_url}")
         |> assign(:invites, Accounts.list_invites())
         |> push_patch(to: ~p"/admin/invites")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not create invite.")}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/invites")}
  end
end
