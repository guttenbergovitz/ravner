defmodule Ravner.ApiKeys.ApiKey do
  @moduledoc """
  Schema for storing encrypted API keys.

  Keys are encrypted (not hashed) so they can be retrieved for API calls.
  The encryption uses Phoenix's secret_key_base for the encryption key.
  """
  use Ecto.Schema
  import Ecto.Changeset

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
  """
  def decrypt_key(%__MODULE__{key_encrypted: encrypted}) when is_binary(encrypted) do
    decrypt_key_value(encrypted)
  end

  def decrypt_key(_), do: nil

  # Encryption using Phoenix's secret_key_base
  defp encrypt_key(plaintext) do
    secret_key_base = Application.get_env(:ravner, RavnerWeb.Endpoint)[:secret_key_base]

    # Derive a 32-byte key from secret_key_base
    key =
      :crypto.hash(:sha256, secret_key_base) |> Base.encode16(case: :lower) |> String.slice(0, 32)

    # Generate random IV
    iv = :crypto.strong_rand_bytes(16)

    # Encrypt
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", true)

    # Combine: iv + tag + ciphertext, then base64 encode
    combined = iv <> tag <> ciphertext
    Base.encode64(combined)
  end

  defp decrypt_key_value(encrypted_base64) do
    secret_key_base = Application.get_env(:ravner, RavnerWeb.Endpoint)[:secret_key_base]

    key =
      :crypto.hash(:sha256, secret_key_base)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 32)

    combined = Base.decode64!(encrypted_base64)
    <<iv::binary-16, tag::binary-16, ciphertext::binary>> = combined

    :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false)
  rescue
    _ -> nil
  end
end
