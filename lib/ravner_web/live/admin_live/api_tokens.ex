defmodule RavnerWeb.AdminLive.ApiTokens do
  @moduledoc """
  Admin LiveView for managing enterprise API tokens.

  Allows administrators to:
  - View all generated API tokens, prefixes, scopes, and statuses.
  - Generate new API tokens with role assignment (:viewer default, :editor, :admin).
  - Configure source perimeter allowlists (IP / CIDR).
  - Configure request URL & method pattern scoping.
  - Set expiration periods (30 days, 90 days, 1 year, custom, or never).
  - Immediately revoke compromised or obsolete tokens.
  - Displays generated secret strictly once upon creation with quick copy.
  """

  use RavnerWeb, :live_view

  alias Ravner.Accounts
  alias Ravner.Accounts.ApiToken

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_scope.user.role == :admin do
      tokens = Accounts.list_api_tokens(actor: socket.assigns.current_scope.user)

      {:ok,
       socket
       |> assign(:page_title, "API Tokens")
       |> assign(:tokens, tokens)
       |> assign(:show_create_modal, false)
       |> assign(:show_secret_modal, false)
       |> assign(:generated_secret, nil)
       |> assign(:form, default_form())}
    else
      {:ok,
       socket
       |> put_flash(:error, "Administrator access required.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_modal, true)
     |> assign(:form, default_form())}
  end

  @impl true
  def handle_event("close_create_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, false)}
  end

  @impl true
  def handle_event("close_secret_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_secret_modal, false)
     |> assign(:generated_secret, nil)}
  end

  @impl true
  def handle_event("save_token", %{"token" => params}, socket) do
    actor = socket.assigns.current_scope.user

    allowed_ips =
      params["allowed_ips"]
      |> to_string()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    allowed_paths =
      params["allowed_paths"]
      |> to_string()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    expires_at = parse_expiry(params["expiry_preset"])

    attrs = %{
      name: String.trim(params["name"] || ""),
      role: String.to_existing_atom(params["role"] || "viewer"),
      allowed_ips: allowed_ips,
      allowed_paths: allowed_paths,
      expires_at: expires_at,
      created_by_user_id: actor.id
    }

    case Accounts.create_api_token(attrs, actor: actor) do
      {:ok, _token, raw_secret} ->
        tokens = Accounts.list_api_tokens(actor: actor)

        {:noreply,
         socket
         |> assign(:tokens, tokens)
         |> assign(:show_create_modal, false)
         |> assign(:show_secret_modal, true)
         |> assign(:generated_secret, raw_secret)
         |> put_flash(:info, "API Token generated successfully.")}

      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to create API token: #{inspect(error)}")}
    end
  end

  @impl true
  def handle_event("revoke_token", %{"id" => id_str}, socket) do
    actor = socket.assigns.current_scope.user
    id = String.to_integer(id_str)

    with {:ok, token} <- Accounts.get_api_token(id, actor: actor),
         {:ok, _revoked} <- Accounts.revoke_api_token(token, actor: actor) do
      tokens = Accounts.list_api_tokens(actor: actor)

      {:noreply,
       socket
       |> assign(:tokens, tokens)
       |> put_flash(:info, "API Token has been revoked.")}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Could not revoke API token.")}
    end
  end

  defp default_form do
    %{
      "name" => "",
      "role" => "viewer",
      "expiry_preset" => "90",
      "allowed_ips" => "",
      "allowed_paths" => "GET /api/v1/*"
    }
  end

  defp parse_expiry("30"), do: DateTime.utc_now() |> DateTime.add(30 * 86400, :second)
  defp parse_expiry("90"), do: DateTime.utc_now() |> DateTime.add(90 * 86400, :second)
  defp parse_expiry("365"), do: DateTime.utc_now() |> DateTime.add(365 * 86400, :second)
  defp parse_expiry("never"), do: nil
  defp parse_expiry(_), do: DateTime.utc_now() |> DateTime.add(90 * 86400, :second)

  def status_badge(%ApiToken{} = token) do
    now = DateTime.utc_now()

    cond do
      not is_nil(token.revoked_at) ->
        {:revoked, "Revoked",
         "bg-red-50 text-red-700 border-red-200 dark:bg-red-900/30 dark:text-red-400"}

      not is_nil(token.expires_at) and DateTime.compare(token.expires_at, now) == :lt ->
        {:expired, "Expired",
         "bg-amber-50 text-amber-700 border-amber-200 dark:bg-amber-900/30 dark:text-amber-400"}

      true ->
        {:active, "Active",
         "bg-emerald-50 text-emerald-700 border-emerald-200 dark:bg-emerald-900/30 dark:text-emerald-400"}
    end
  end
end
