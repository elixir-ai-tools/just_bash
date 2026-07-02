defmodule JustBash.Network do
  @moduledoc """
  Shared network policy enforcement for sandbox HTTP commands (curl, wget).

  Enforces the caller's network configuration:

  - **Enabled gate** — network must be explicitly enabled.
  - **Scheme enforcement** — only `https://` by default; `http://` requires the
    caller to set `allow_insecure: true`.
  - **Allow-list** — each host is checked against the configured patterns.
    An empty list blocks everything; `:all` permits any host.
  - **Redirect validation** — every redirect target is re-checked against the
    same policy. The HTTP library's built-in redirect following is disabled so
    that a `301 → http://evil.com` cannot bypass the allow-list.
  """

  @max_redirects 10

  @doc """
  Validates that `url` is permitted under `bash`'s network config.

  Returns `:ok` or `{:error, message}`. The `command_name` (e.g. `"curl"`) is
  included in error messages for user-facing output.
  """
  @spec validate_access(JustBash.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_access(bash, url, command_name) do
    network = Map.get(bash, :network, %{})
    enabled = Map.get(network, :enabled, false)
    allow_list = Map.get(network, :allow_list, [])
    allow_insecure = Map.get(network, :allow_insecure, false)

    cond do
      not enabled ->
        {:error, "#{command_name}: network access is disabled\n"}

      not scheme_allowed?(url, allow_insecure) ->
        {:error,
         "#{command_name}: plain HTTP is not allowed; use https:// or set allow_insecure: true in network config\n"}

      not host_allowed?(url, allow_list) ->
        {:error, "#{command_name}: access to #{url} is not allowed\n"}

      true ->
        :ok
    end
  end

  @doc """
  Follows redirects manually, re-validating each target against the network policy.

  `request_fn` is called with the current request map and must return
  `{:ok, response}` or `{:error, error}`.

  `on_redirect` is called as `on_redirect.(status, request)` and must return
  the updated request map. Curl uses this to adjust the HTTP method on 303/307/308;
  wget uses the default (identity) since it only issues GET requests.

  Returns:
  - `{:response, response}` — terminal HTTP response (not a redirect, or redirect
    without a Location header)
  - `{:error, error}` — transport failure or network policy violation
  """
  @spec follow_redirects(
          JustBash.t(),
          map(),
          String.t(),
          (map() -> {:ok, map()} | {:error, map()}),
          (integer(), map() -> map())
        ) :: {:response, map()} | {:error, map()}
  def follow_redirects(
        bash,
        request,
        command_name,
        request_fn,
        on_redirect \\ &identity_redirect/2
      ) do
    do_follow(bash, request, command_name, request_fn, on_redirect, @max_redirects)
  end

  defp do_follow(_bash, request, command_name, _request_fn, _on_redirect, 0) do
    {:error, %{reason: "#{command_name}: #{request.url}: too many redirects\n"}}
  end

  defp do_follow(bash, request, command_name, request_fn, on_redirect, remaining) do
    case request_fn.(request) do
      {:ok, %{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        maybe_follow(
          bash,
          request,
          response,
          status,
          command_name,
          request_fn,
          on_redirect,
          remaining
        )

      {:ok, response} ->
        {:response, response}

      {:error, _} = error ->
        error
    end
  end

  defp maybe_follow(
         bash,
         request,
         response,
         status,
         command_name,
         request_fn,
         on_redirect,
         remaining
       ) do
    case get_location_header(response.headers) do
      nil ->
        {:response, response}

      redirect_location ->
        redirect_url = resolve_redirect_url(request.url, redirect_location)

        case validate_access(bash, redirect_url, command_name) do
          {:error, msg} ->
            {:error, %{reason: msg}}

          :ok ->
            new_request = on_redirect.(status, %{request | url: redirect_url})
            do_follow(bash, new_request, command_name, request_fn, on_redirect, remaining - 1)
        end
    end
  end

  @doc """
  Extracts the `location` header from a response headers map.
  """
  @spec get_location_header(map() | term()) :: String.t() | nil
  def get_location_header(headers) when is_map(headers) do
    case Map.get(headers, "location") do
      [url | _] -> url
      url when is_binary(url) -> url
      _ -> nil
    end
  end

  def get_location_header(_), do: nil

  # Default on_redirect — returns the request unchanged (appropriate for GET-only commands).
  defp identity_redirect(_status, request), do: request

  defp resolve_redirect_url(current_url, location) do
    current_url
    |> URI.merge(location)
    |> URI.to_string()
  end

  defp scheme_allowed?(url, allow_insecure) do
    case URI.parse(url).scheme do
      "https" -> true
      "http" -> allow_insecure
      _ -> false
    end
  end

  defp host_allowed?(_url, :all), do: true
  defp host_allowed?(_url, []), do: false

  defp host_allowed?(url, allow_list) do
    host = URI.parse(url).host || ""
    Enum.any?(allow_list, &pattern_matches?(&1, host))
  end

  defp pattern_matches?("*", _host), do: true
  defp pattern_matches?("**", _host), do: true

  defp pattern_matches?("*." <> domain, host) do
    String.ends_with?(host, "." <> domain) or host == domain
  end

  defp pattern_matches?(pattern, host), do: host == pattern
end
