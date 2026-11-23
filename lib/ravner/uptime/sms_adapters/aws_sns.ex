defmodule Ravner.Uptime.SmsAdapters.AwsSns do
  @moduledoc """
  SMS delivery via AWS SNS using Req + AWS Signature V4.
  Credentials from env: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION.
  """
  @behaviour Ravner.Uptime.SmsAdapter

  require Logger

  @impl true
  def send_sms(to, body, opts) do
    region = Keyword.get(opts, :region, System.get_env("AWS_REGION", "eu-central-1"))
    sender_id = Keyword.get(opts, :sender_id, "Ravner")

    params = %{
      "Action" => "Publish",
      "Version" => "2010-03-31",
      "PhoneNumber" => to,
      "Message" => body,
      "MessageAttributes.entry.1.Name" => "AWS.SNS.SMS.SenderID",
      "MessageAttributes.entry.1.Value.DataType" => "String",
      "MessageAttributes.entry.1.Value.StringValue" => sender_id
    }

    url = "https://sns.#{region}.amazonaws.com/"

    # ponytail: uses Req with manual SigV4 signing; upgrade path: ex_aws_sns dep
    case sign_and_post(url, params, region) do
      {:ok, %{status: 200, body: resp_body}} ->
        case Regex.run(~r/<MessageId>(.+?)<\/MessageId>/, resp_body) do
          [_, message_id] -> {:ok, message_id}
          _ -> {:ok, "sns_ok"}
        end

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("[SMS:AwsSns] HTTP #{status}: #{resp_body}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("[SMS:AwsSns] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp sign_and_post(url, params, region) do
    access_key = System.get_env("AWS_ACCESS_KEY_ID")
    secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")

    if is_nil(access_key) || is_nil(secret_key) do
      {:error, :missing_aws_credentials}
    else
      body = URI.encode_query(params)
      now = DateTime.utc_now()
      date = Calendar.strftime(now, "%Y%m%d")
      datetime = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")

      host = "sns.#{region}.amazonaws.com"

      headers = [
        {"content-type", "application/x-www-form-urlencoded"},
        {"host", host},
        {"x-amz-date", datetime}
      ]

      signed_headers = "content-type;host;x-amz-date"
      payload_hash = sha256_hex(body)

      canonical =
        Enum.join(
          [
            "POST",
            "/",
            "",
            "content-type:application/x-www-form-urlencoded\nhost:#{host}\nx-amz-date:#{datetime}",
            "",
            signed_headers,
            payload_hash
          ],
          "\n"
        )

      scope = "#{date}/#{region}/sns/aws4_request"
      string_to_sign = "AWS4-HMAC-SHA256\n#{datetime}\n#{scope}\n#{sha256_hex(canonical)}"

      k_date = hmac("AWS4#{secret_key}", date)
      k_region = hmac(k_date, region)
      k_service = hmac(k_region, "sns")
      k_signing = hmac(k_service, "aws4_request")

      signature = hmac_hex(k_signing, string_to_sign)

      auth =
        "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

      all_headers = [{"authorization", auth} | headers]

      Req.post(url, body: body, headers: all_headers)
    end
  end

  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hmac_hex(key, data), do: hmac(key, data) |> Base.encode16(case: :lower)
end
