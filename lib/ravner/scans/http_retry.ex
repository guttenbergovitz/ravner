defmodule Ravner.Scans.HttpRetry do
  @moduledoc """
  HTTP request helper with exponential backoff retry for transient failures.

  Retries on:
  - Connection errors (timeout, refused, closed)
  - 5xx server errors
  - Rate limiting (429)

  Does NOT retry on:
  - 4xx client errors (except 429)
  - Successful responses
  """

  require Logger

  @default_max_retries 2
  @default_base_delay_ms 500
  @default_max_delay_ms 5_000

  @type retry_opts :: [
          max_retries: non_neg_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer()
        ]

  @doc """
  Wraps a Req request function with retry logic.

  ## Options
  - `:max_retries` - Maximum retry attempts (default: 2)
  - `:base_delay_ms` - Base delay between retries (default: 500ms)
  - `:max_delay_ms` - Maximum delay cap (default: 5000ms)

  ## Example

      HttpRetry.with_retry(fn ->
        Req.get("https://api.example.com/data", receive_timeout: 8_000)
      end, max_retries: 3)
  """
  @spec with_retry((-> {:ok, any()} | {:error, any()}), retry_opts()) ::
          {:ok, any()} | {:error, any()}
  def with_retry(request_fn, opts \\ []) when is_function(request_fn, 0) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    base_delay = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    max_delay = Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)

    do_retry(request_fn, 0, max_retries, base_delay, max_delay)
  end

  defp do_retry(request_fn, attempt, max_retries, base_delay, max_delay) do
    case request_fn.() do
      {:ok, %{status: status} = response} when status >= 500 ->
        maybe_retry(
          request_fn,
          attempt,
          max_retries,
          base_delay,
          max_delay,
          {:ok, response},
          "HTTP #{status}"
        )

      {:ok, %{status: 429} = response} ->
        # Rate limited - check for Retry-After header
        retry_after = extract_retry_after(response)

        delay =
          if retry_after,
            do: retry_after * 1000,
            else: calculate_delay(attempt, base_delay, max_delay)

        maybe_retry(
          request_fn,
          attempt,
          max_retries,
          base_delay,
          max_delay,
          {:ok, response},
          "rate limited (429)",
          delay
        )

      {:ok, _response} = success ->
        success

      {:error, %Req.TransportError{reason: reason}} = error when reason in [:timeout, :closed] ->
        maybe_retry(
          request_fn,
          attempt,
          max_retries,
          base_delay,
          max_delay,
          error,
          "transport #{reason}"
        )

      {:error, %Mint.TransportError{reason: reason}} = error when reason in [:timeout, :closed] ->
        maybe_retry(
          request_fn,
          attempt,
          max_retries,
          base_delay,
          max_delay,
          error,
          "transport #{reason}"
        )

      {:error, _reason} = error ->
        # Non-retryable error
        error
    end
  end

  defp maybe_retry(
         request_fn,
         attempt,
         max_retries,
         base_delay,
         max_delay,
         last_result,
         reason,
         override_delay \\ nil
       ) do
    if attempt < max_retries do
      delay = override_delay || calculate_delay(attempt, base_delay, max_delay)

      Logger.debug(
        "Retrying request after #{reason}, attempt #{attempt + 1}/#{max_retries}, delay #{delay}ms"
      )

      Process.sleep(delay)
      do_retry(request_fn, attempt + 1, max_retries, base_delay, max_delay)
    else
      last_result
    end
  end

  defp calculate_delay(attempt, base_delay, max_delay) do
    # Exponential backoff with jitter
    base = (base_delay * :math.pow(2, attempt)) |> round()
    jitter = :rand.uniform(div(base, 4))
    min(base + jitter, max_delay)
  end

  defp extract_retry_after(%{headers: headers}) when is_map(headers) do
    case Map.get(headers, "retry-after") do
      [value | _] -> parse_retry_after(value)
      value when is_binary(value) -> parse_retry_after(value)
      _ -> nil
    end
  end

  defp extract_retry_after(_), do: nil

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds > 0 and seconds <= 300 -> seconds
      _ -> nil
    end
  end

  defp parse_retry_after(_), do: nil
end
