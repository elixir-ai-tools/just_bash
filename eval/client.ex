defmodule JustBash.Eval.Client do
  @moduledoc """
  Minimal Anthropic API client for the eval agent loop.

  Includes retry with exponential backoff for transient failures (429, 500, 529).
  Tracks token usage from API responses.
  """

  @api_url "https://api.anthropic.com/v1/messages"
  @model "claude-haiku-4-5-20251001"
  @max_retries 3
  @base_delay_ms 1_000
  @retryable_statuses [429, 500, 502, 503, 529]

  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}

  def chat(messages, opts \\ []) do
    api_key = api_key!()
    tools = Keyword.get(opts, :tools, [])
    system = Keyword.get(opts, :system, nil)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    body =
      %{
        model: @model,
        max_tokens: max_tokens,
        messages: messages
      }
      |> maybe_put(:system, system)
      |> maybe_put(:tools, if(tools != [], do: tools))

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    do_request(body, headers, 0)
  end

  defp do_request(body, headers, attempt) do
    case Req.post(@api_url,
           json: body,
           headers: headers,
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        usage = extract_usage(resp_body)
        {:ok, Map.put(resp_body, "usage", usage)}

      {:ok, %{status: status, body: resp_body}} when status in @retryable_statuses ->
        if attempt < @max_retries do
          delay = backoff_delay(attempt)
          Process.sleep(delay)
          do_request(body, headers, attempt + 1)
        else
          {:error, {status, resp_body}}
        end

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {status, resp_body}}

      {:error, %Req.TransportError{} = error} ->
        if attempt < @max_retries do
          delay = backoff_delay(attempt)
          Process.sleep(delay)
          do_request(body, headers, attempt + 1)
        else
          {:error, error}
        end

      {:error, reason} ->
        if attempt < @max_retries do
          delay = backoff_delay(attempt)
          Process.sleep(delay)
          do_request(body, headers, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  defp backoff_delay(attempt) do
    # Exponential backoff with jitter: base * 2^attempt + random(0..base)
    base = @base_delay_ms * Integer.pow(2, attempt)
    jitter = :rand.uniform(@base_delay_ms)
    base + jitter
  end

  defp extract_usage(%{"usage" => %{"input_tokens" => input, "output_tokens" => output}}) do
    %{input_tokens: input, output_tokens: output}
  end

  defp extract_usage(_), do: %{input_tokens: 0, output_tokens: 0}

  defp api_key! do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> raise "Missing ANTHROPIC_API_KEY environment variable"
      "" -> raise "ANTHROPIC_API_KEY is empty"
      key -> key
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
