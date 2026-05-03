defmodule Ravner.ApiKeys.ApiKey do
  @moduledoc """
  Schema for storing encrypted API keys.

  Keys are encrypted (not hashed) so they can be retrieved for API calls.

  ## Encryption

  Encryption uses AES-256-GCM. The 32-byte key is derived from
  `secret_key_base` via PBKDF2 (`Plug.Crypto.KeyGenerator`) with a fixed
  per-purpose salt to provide domain separation from other uses of the
  secret.

  Ciphertext is versioned to allow future key-derivation changes:

    * `v1$<base64(iv ++ tag ++ ciphertext)>` — current format
    * `<base64(iv ++ tag ++ ciphertext)>`    — legacy format (sha256
      hex-truncated key); still decrypted for backward compatibility

  Re-saving a key (e.g. via `changeset_with_key/2`) will upgrade the
  stored ciphertext to the latest format.
  """
  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  @kdf_salt "Ravner.ApiKeys.ApiKey/aes-256-gcm/v1"
  @kdf_iterations 10_000
  @v1_prefix "v1$"

  schema "api_keys" do
    field(:name, :string)
    field(:key_encrypted, :string)
    field(:key_type, :string, default: "settings")
    field(:last_validated_at, :utc_datetime)
    field(:is_valid, :boolean, default: nil)
    field(:error_message, :string)

    # Virtual field for receiving the key in forms (not stored)
    field(:key, :string, virtual: true)

    timestamps(type: :utc_datetime)
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :key_type, :last_validated_at, :is_valid, :error_message])
    |> validate_required([:name, :key_type])
    |> unique_constraint(:name)
  end

  def changeset_with_key(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :key_type, :key])
    |> validate_required([:name, :key_type])
    |> unique_constraint(:name)
    |> maybe_encrypt_key(attrs)
  end

  defp maybe_encrypt_key(changeset, attrs) do
    case get_change(changeset, :key) || attrs["key"] || attrs[:key] do
      nil ->
        changeset

      "" ->
        changeset

      key ->
        encrypted = encrypt_key(key)
        put_change(changeset, :key_encrypted, encrypted)
    end
  end

  @doc """
  Decrypts the stored key for use in API calls.

  Returns the plaintext on success, or `nil` if the ciphertext is
  malformed, tampered with, or cannot be decrypted with the current
  secret.
  """
  def decrypt_key(%__MODULE__{key_encrypted: encrypted}) when is_binary(encrypted) do
    decrypt_key_value(encrypted)
  end

  def decrypt_key(_), do: nil

  # --- Encryption ---------------------------------------------------------

  defp encrypt_key(plaintext) do
    key = derive_key(:v1)
    iv = :crypto.strong_rand_bytes(16)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", true)

    @v1_prefix <> Base.encode64(iv <> tag <> ciphertext)
  end

  defp decrypt_key_value(@v1_prefix <> base64) do
    do_decrypt(base64, derive_key(:v1))
  end

  defp decrypt_key_value(legacy_base64) do
    do_decrypt(legacy_base64, derive_key(:legacy))
  end

  defp do_decrypt(base64, key) do
    with {:ok, combined} <- Base.decode64(base64),
         <<iv::binary-16, tag::binary-16, ciphertext::binary>> <- combined,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
      plaintext
    else
      :error ->
        Logger.warning("ApiKey decrypt: malformed base64 ciphertext")
        nil

      {:error, reason} ->
        Logger.warning("ApiKey decrypt failed: #{inspect(reason)}")
        nil

      _other ->
        Logger.warning("ApiKey decrypt failed: ciphertext truncated or auth tag mismatch")
        nil
    end
  rescue
    error ->
      Logger.warning("ApiKey decrypt raised: #{Exception.message(error)}")
      nil
  end

  # --- Key derivation -----------------------------------------------------

  defp derive_key(:v1) do
    Plug.Crypto.KeyGenerator.generate(secret_key_base(), @kdf_salt,
      iterations: @kdf_iterations,
      length: 32,
      digest: :sha256
    )
  end

  # Legacy derivation: sha256(secret) -> hex -> first 32 ASCII chars.
  # Kept ONLY to decrypt rows written before the v1 format existed.
  defp derive_key(:legacy) do
    :crypto.hash(:sha256, secret_key_base())
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp secret_key_base do
    Application.get_env(:ravner, RavnerWeb.Endpoint)[:secret_key_base] ||
      raise "secret_key_base is not configured for RavnerWeb.Endpoint"
  end
end
