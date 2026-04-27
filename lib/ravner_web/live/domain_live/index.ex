defmodule RavnerWeb.DomainLive.Index do
  use RavnerWeb, :live_view

  alias Ravner.Domains
  alias Ravner.Domains.Domain

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :domains, Domains.list_domains_with_preloads())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Domains")
    |> assign(:domain, nil)
  end

  defp apply_action(socket, :new, _params) do
    changeset = Domains.change_domain(%Domain{})

    socket
    |> assign(:page_title, "New Domain")
    |> assign(:domain, %Domain{})
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :import, _params) do
    socket
    |> assign(:page_title, "Import Domains")
    |> assign(:domain, nil)
    |> assign(:import_results, nil)
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
    case Domains.create_domain(domain_params) do
      {:ok, domain} ->
        {:noreply,
         socket
         |> put_flash(:info, "Domain created successfully")
         |> push_navigate(to: ~p"/domains")
         |> stream_insert(:domains, domain)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    domain = Domains.get_domain!(id)
    {:ok, _} = Domains.delete_domain(domain)

    {:noreply, stream_delete(socket, :domains, domain)}
  end

  def handle_event("import", %{"domains" => domains_text}, socket) do
    lines =
      domains_text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    results =
      Enum.map(lines, fn line ->
        case validate_domain(line) do
          :ok ->
            case Domains.create_domain(%{name: line, type: domain_type(line)}) do
              {:ok, domain} -> {:ok, domain}
              {:error, changeset} -> {:error, line, changeset}
            end

          {:error, reason} ->
            {:error, line, reason}
        end
      end)

    successful = Enum.filter(results, &match?({:ok, _}, &1))
    failed = Enum.reject(results, &match?({:ok, _}, &1))

    socket =
      socket
      |> assign(:import_results, %{
        total: length(lines),
        successful: length(successful),
        failed: failed
      })

    socket =
      Enum.reduce(successful, socket, fn {:ok, domain}, acc ->
        stream_insert(acc, :domains, domain)
      end)

    {:noreply, socket}
  end

  defp validate_domain(name) do
    if Regex.match?(~r/^[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z0-9][-a-zA-Z0-9.]*$/, name) do
      :ok
    else
      {:error, "invalid domain format"}
    end
  end

  defp domain_type(name) do
    parts = String.split(name, ".")

    if length(parts) > 2 do
      :subdomain
    else
      :domain
    end
  end

  defp lifecycle_color(:active), do: "bg-green-500"
  defp lifecycle_color(:under_review), do: "bg-yellow-500"
  defp lifecycle_color(:deprecated), do: "bg-orange-500"
  defp lifecycle_color(:decommissioned), do: "bg-red-500"
  defp lifecycle_color(:abandoned), do: "bg-neutral-400"
  defp lifecycle_color(_), do: "bg-neutral-400"
end
