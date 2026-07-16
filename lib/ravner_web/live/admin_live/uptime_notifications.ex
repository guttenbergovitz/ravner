defmodule RavnerWeb.AdminLive.UptimeNotifications do
  use RavnerWeb, :live_view

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Uptime.{NotificationPolicy, NotificationGroup, NotificationRecipient}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Uptime Notifications")
     |> assign(:active_tab, :policies)
     |> load_data()}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("create_global_policy", _params, socket) do
    case Repo.insert(
           %NotificationPolicy{name: "Global Policy", scope: "global", enabled: true},
           on_conflict: :nothing
         ) do
      {:ok, _} -> {:noreply, load_data(socket) |> put_flash(:info, "Global policy created.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed.")}
    end
  end

  @impl true
  def handle_event("create_group", %{"name" => name}, socket) do
    case %NotificationGroup{} |> NotificationGroup.changeset(%{name: name}) |> Repo.insert() do
      {:ok, _} -> {:noreply, load_data(socket) |> put_flash(:info, "Group created.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed — name may already exist.")}
    end
  end

  @impl true
  def handle_event("add_recipient", params, socket) do
    attrs = %{
      policy_id: parse_id(params["policy_id"]),
      group_id: parse_id(params["group_id"]),
      user_id: parse_id(params["user_id"]),
      email: blank_to_nil(params["email"]),
      phone: blank_to_nil(params["phone"]),
      channels: params["channels"] || "email"
    }

    case %NotificationRecipient{} |> NotificationRecipient.changeset(attrs) |> Repo.insert() do
      {:ok, _} -> {:noreply, load_data(socket) |> put_flash(:info, "Recipient added.")}
      {:error, _cs} -> {:noreply, put_flash(socket, :error, "Failed to add recipient.")}
    end
  end

  @impl true
  def handle_event("delete_recipient", %{"id" => id}, socket) do
    Repo.get!(NotificationRecipient, id) |> Repo.delete!()
    {:noreply, load_data(socket) |> put_flash(:info, "Removed.")}
  end

  @impl true
  def handle_event("delete_group", %{"id" => id}, socket) do
    Repo.get!(NotificationGroup, id) |> Repo.delete!()
    {:noreply, load_data(socket) |> put_flash(:info, "Group removed.")}
  end

  defp load_data(socket) do
    policies =
      NotificationPolicy
      |> order_by(asc: :scope)
      |> Repo.all()
      |> Repo.preload([:recipients, :domain])

    groups =
      NotificationGroup
      |> order_by(asc: :name)
      |> Repo.all()
      |> Repo.preload(:recipients)

    users =
      Ravner.Accounts.User
      |> where(active: true)
      |> order_by(asc: :name)
      |> Repo.all()

    sms_adapter =
      Application.get_env(:ravner, :uptime_sms_adapter)
      |> Module.split()
      |> List.last()

    socket
    |> assign(:policies, policies)
    |> assign(:groups, groups)
    |> assign(:users, users)
    |> assign(:sms_adapter, sms_adapter)
  end

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil
  defp parse_id(s) when is_binary(s), do: String.to_integer(s)
  defp parse_id(i), do: i

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s
end
