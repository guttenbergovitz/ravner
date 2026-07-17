defmodule Ravner.DeliverySettings do
  @moduledoc """
  DB-backed configuration for email and SMS delivery providers.
  Settings are stored encrypted and take precedence over env vars.
  """

  alias Ravner.Repo

  defmodule Setting do
    use Ecto.Schema
    import Ecto.Changeset

    schema "delivery_settings" do
      field :key, :string
      field :value_encrypted, :binary
      field :value_plain, :string

      timestamps(type: :utc_datetime)
    end

    def changeset(setting, attrs) do
      setting
      |> cast(attrs, [:key, :value_encrypted, :value_plain])
      |> validate_required([:key])
      |> unique_constraint(:key)
    end
  end

  # --- Email providers ---
  @email_providers %{
    "smtp" => %{
      label: "SMTP",
      fields: ["smtp_host", "smtp_port", "smtp_username", "smtp_password", "smtp_ssl"]
    },
    "aws_ses" => %{
      label: "Amazon SES",
      fields: ["ses_region", "ses_access_key", "ses_secret_key"]
    },
    "sendgrid" => %{label: "SendGrid", fields: ["sendgrid_api_key"]},
    "mailgun" => %{label: "Mailgun", fields: ["mailgun_api_key", "mailgun_domain"]},
    "postmark" => %{label: "Postmark", fields: ["postmark_api_key"]}
  }

  # --- SMS providers ---
  @sms_providers %{
    "aws_sns" => %{
      label: "Amazon SNS",
      fields: ["sns_region", "sns_access_key", "sns_secret_key", "sns_sender_id"]
    },
    "twilio" => %{
      label: "Twilio",
      fields: ["twilio_account_sid", "twilio_auth_token", "twilio_from_number"]
    },
    "log" => %{label: "Log (dev/test)", fields: []}
  }

  def email_providers, do: @email_providers
  def sms_providers, do: @sms_providers

  # --- CRUD ---

  def get(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> nil
      %{value_plain: val} when is_binary(val) and val != "" -> val
      %{value_encrypted: enc} when is_binary(enc) -> decrypt(enc)
      _ -> nil
    end
  end

  def get_all do
    Setting
    |> Repo.all()
    |> Map.new(fn s ->
      val =
        if s.value_plain && s.value_plain != "",
          do: s.value_plain,
          else: decrypt(s.value_encrypted)

      {s.key, val}
    end)
  end

  def set(key, value, opts \\ []) do
    secret? = Keyword.get(opts, :secret, false)

    attrs =
      if secret? do
        %{key: key, value_encrypted: encrypt(value), value_plain: nil}
      else
        %{key: key, value_plain: value, value_encrypted: nil}
      end

    case Repo.get_by(Setting, key: key) do
      nil ->
        %Setting{}
        |> Setting.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> Setting.changeset(attrs)
        |> Repo.update()
    end
  end

  def delete(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> :ok
      setting -> Repo.delete(setting)
    end
  end

  # --- Provider helpers ---

  def current_email_provider do
    get("email_provider") || "smtp"
  end

  def current_sms_provider do
    get("sms_provider") || "log"
  end

  def email_from_name, do: get("email_from_name") || "Ravner"
  def email_from_address, do: get("email_from_address") || "noreply@example.com"

  # --- Encryption (reuses Phoenix secret_key_base) ---

  defp encrypt(nil), do: nil
  defp encrypt(""), do: nil

  defp encrypt(value) do
    secret = secret_key()
    :crypto.crypto_one_time(:aes_256_ctr, secret, <<0::128>>, value, true)
  end

  defp decrypt(nil), do: nil

  defp decrypt(ciphertext) do
    secret = secret_key()
    :crypto.crypto_one_time(:aes_256_ctr, secret, <<0::128>>, ciphertext, false)
  rescue
    _ -> nil
  end

  defp secret_key do
    RavnerWeb.Endpoint.config(:secret_key_base)
    |> binary_part(0, 32)
  end
end
