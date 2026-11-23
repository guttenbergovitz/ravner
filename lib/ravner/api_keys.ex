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
    }
  ]

  @spec list_known_keys() :: [map()]
  def list_known_keys, do: @known_keys

  @spec list_api_keys() :: [ApiKey.t()]
  def list_api_keys do
    Repo.all(from(k in ApiKey, order_by: [asc: k.name]))
  end

  @spec get_api_key!(integer() | String.t()) :: ApiKey.t()
  def get_api_key!(id), do: Repo.get!(ApiKey, id)

  @spec get_api_key_by_name(String.t()) :: ApiKey.t() | nil
  def get_api_key_by_name(name), do: Repo.get_by(ApiKey, name: name)

  @spec create_api_key(map()) :: {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def create_api_key(attrs \\ %{}) do
    %ApiKey{}
    |> ApiKey.changeset_with_key(attrs)
    |> Repo.insert()
  end

  @spec update_api_key(ApiKey.t(), map()) :: {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def update_api_key(%ApiKey{} = api_key, attrs) do
    api_key
    |> ApiKey.changeset_with_key(attrs)
    |> Repo.update()
  end

  @spec delete_api_key(ApiKey.t()) :: {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def delete_api_key(%ApiKey{} = api_key), do: Repo.delete(api_key)

  @spec change_api_key(ApiKey.t(), map()) :: Ecto.Changeset.t()
  def change_api_key(%ApiKey{} = api_key, attrs \\ %{}), do: ApiKey.changeset(api_key, attrs)

  @spec get_effective_key(atom() | String.t()) ::
          {:settings | :env | :none, String.t() | nil, ApiKey.t() | nil}
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

  @spec key_configured?(atom() | String.t()) :: boolean()
  def key_configured?(service_name) do
    case get_effective_key(service_name) do
      {:none, _, _} -> false
      _ -> true
    end
  end

  @spec get_key_source(atom() | String.t()) :: :settings | :env | :none
  def get_key_source(service_name) do
    case get_effective_key(service_name) do
      {:settings, _, _} -> :settings
      {:env, _, _} -> :env
      {:none, _, _} -> :none
    end
  end

  @spec validate_key(String.t()) :: {:ok, :valid} | {:error, String.t()}
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
        case Ravner.SystemCommand.run_with_timeout(
               "lonkero",
               ["license", "status", "-L", key],
               10_000
             ) do
          {output, 0} ->
            lower_out = String.downcase(output)

            if String.contains?(lower_out, "invalid") or String.contains?(lower_out, "failed") do
              {:error, String.trim(output)}
            else
              :ok
            end

          {:error, :timeout} ->
            {:error, "lonkero license check timed out"}

          {:error, reason} ->
            {:error, reason}

          {output, _} ->
            {:error, String.trim(output)}
        end
    end
  end

  defp do_validate(s), do: {:error, "Validation not implemented for #{s}"}

  defp trunc(s, n) when is_binary(s) and byte_size(s) > n, do: String.slice(s, 0, n) <> "..."
  defp trunc(s, _) when is_binary(s), do: s

  @doc """
  Validates all known API keys at startup. Logs warnings for missing required keys
  and errors for invalid configured keys. Does not block startup.
  """
  @spec validate_on_startup() :: :ok
  def validate_on_startup do
    # Skip in test environment
    if Application.get_env(:ravner, :env) == :test do
      :ok
    else
      do_startup_validation()
    end
  end

  defp do_startup_validation do
    Logger.info("[ApiKeys] Checking API key configuration...")

    results =
      @known_keys
      |> Enum.map(fn %{name: name, label: label, required: required} ->
        case get_effective_key(name) do
          {:none, _, _} ->
            if required do
              Logger.warning(
                "[ApiKeys] #{label} (#{name}) — NOT CONFIGURED (required for some features)"
              )
            else
              Logger.debug("[ApiKeys] #{label} (#{name}) — not configured (optional)")
            end

            {name, :missing, required}

          {source, _key, _} ->
            Logger.info("[ApiKeys] #{label} (#{name}) — configured via #{source}")
            {name, :configured, required}
        end
      end)

    missing_required =
      Enum.filter(results, fn {_, status, required} -> status == :missing and required end)

    if missing_required != [] do
      names = Enum.map(missing_required, fn {name, _, _} -> name end) |> Enum.join(", ")

      Logger.warning(
        "[ApiKeys] Missing required keys: #{names}. Some scan features will be degraded."
      )
    end

    :ok
  end
end
