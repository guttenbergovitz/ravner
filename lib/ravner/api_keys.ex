defmodule Ravner.ApiKeys do
  @moduledoc """
  The ApiKeys context for managing external service API keys.

  Keys are encrypted (not hashed) so they can be retrieved for API calls.
  The encryption key is derived from Phoenix's secret_key_base.

  Discovery order: settings > ENV (settings has precedence)
  """

  import Ecto.Query, warn: false
  alias Ravner.ApiKeys.ApiKey
  alias Ravner.Repo

  require Logger

  @known_keys [
    %{
      name: "chaos",
      label: "ProjectDiscovery Chaos",
      description: "Subdomain discovery via Chaos API",
      required: true
    },
    %{
      name: "lonkero",
      label: "Lonkero License",
      description: "Commercial license key for Lonkero vulnerability scanner (optional)",
      required: false
    },
    %{
      name: "securitytrails",
      label: "SecurityTrails",
      description: "DNS and domain intelligence (optional, not currently used)",
      required: false
    },
    %{
      name: "shodan",
      label: "Shodan",
      description: "Internet-wide scanning (optional, not currently used)",
      required: false
    }
  ]

  def list_known_keys, do: @known_keys

  def list_api_keys do
    Repo.all(from(k in ApiKey, order_by: [asc: k.name]))
  end

  def get_api_key!(id), do: Repo.get!(ApiKey, id)
  def get_api_key_by_name(name), do: Repo.get_by(ApiKey, name: name)

  def create_api_key(attrs \\ %{}) do
    %ApiKey{}
    |> ApiKey.changeset_with_key(attrs)
    |> Repo.insert()
  end

  def update_api_key(%ApiKey{} = api_key, attrs) do
    api_key
    |> ApiKey.changeset_with_key(attrs)
    |> Repo.update()
  end

  def delete_api_key(%ApiKey{} = api_key), do: Repo.delete(api_key)
  def change_api_key(%ApiKey{} = api_key, attrs \\ %{}), do: ApiKey.changeset(api_key, attrs)

  def get_effective_key(service_name) when is_atom(service_name),
    do: get_effective_key(Atom.to_string(service_name))

  def get_effective_key(service_name) when is_binary(service_name) do
    case get_api_key_by_name(service_name) do
      %ApiKey{key_encrypted: enc} = r when is_binary(enc) ->
        case ApiKey.decrypt_key(r) do
          nil -> {:none, nil, r}
          key -> {:settings, key, r}
        end

      _ ->
        env = System.get_env("#{String.upcase(service_name)}_API_KEY")
        if is_binary(env) and env != "", do: {:env, env, nil}, else: {:none, nil, nil}
    end
  end

  def key_configured?(service_name) do
    case get_effective_key(service_name) do
      {:none, _, _} -> false
      _ -> true
    end
  end

  def get_key_source(service_name) do
    case get_effective_key(service_name) do
      {:settings, _, _} -> :settings
      {:env, _, _} -> :env
      {:none, _, _} -> :none
    end
  end

  def validate_key(service_name) do
    r = get_api_key_by_name(service_name)

    case do_validate(service_name) do
      :ok ->
        if r,
          do:
            r
            |> ApiKey.changeset(%{
              last_validated_at: DateTime.utc_now(),
              is_valid: true,
              error_message: nil
            })
            |> Repo.update()

        {:ok, :valid}

      {:error, reason} ->
        if r,
          do:
            r
            |> ApiKey.changeset(%{
              last_validated_at: DateTime.utc_now(),
              is_valid: false,
              error_message: trunc(reason, 255)
            })
            |> Repo.update()

        {:error, reason}
    end
  end

  defp do_validate("chaos") do
    case get_effective_key("chaos") do
      {:none, _, _} ->
        {:error, "No API key configured"}

      {_, key, _} when is_binary(key) ->
        case Req.get("https://dns.projectdiscovery.io/dns/google.com/subdomains",
               headers: %{"authorization" => key},
               retry: false,
               receive_timeout: 10_000
             ) do
          {:ok, %{status: 200}} -> :ok
          {:ok, %{status: 401}} -> {:error, "Invalid API key (401)"}
          {:ok, %{status: 403}} -> {:error, "Access denied (403)"}
          {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
          {:error, e} -> {:error, "Request failed: #{inspect(e)}"}
        end

      _ ->
        {:error, "Key not available"}
    end
  end

  defp do_validate("lonkero") do
    case get_effective_key("lonkero") do
      {:none, _, _} ->
        {:error, "No license key configured"}

      {_, key, _} when is_binary(key) ->
        case System.find_executable("lonkero") do
          nil ->
            {:error, "lonkero executable not found"}

          exec ->
            case System.cmd(exec, ["license", "status", "-L", key], stderr_to_stdout: true) do
              {output, 0} ->
                lower_out = String.downcase(output)

                if String.contains?(lower_out, "invalid") or String.contains?(lower_out, "failed") do
                  {:error, String.trim(output)}
                else
                  :ok
                end

              {output, _} ->
                {:error, String.trim(output)}
            end
        end
    end
  end

  defp do_validate(s), do: {:error, "Validation not implemented for #{s}"}

  defp trunc(s, n) when is_binary(s) and byte_size(s) > n, do: String.slice(s, 0, n) <> "..."
  defp trunc(s, _) when is_binary(s), do: s
end
