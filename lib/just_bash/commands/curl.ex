defmodule JustBash.Commands.Curl do
  @moduledoc """
  The `curl` command - transfer data from or to a server.

  Supports:
  - GET, POST, PUT, DELETE, HEAD methods
  - Custom headers (-H)
  - Request body (-d, --data)
  - Output to file (-o)
  - Silent mode (-s)
  - Include headers in output (-i)
  - Follow redirects (-L)
  - Basic authentication (-u)

  Network access must be enabled via the :network option when creating the bash environment.
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @default_timeout 30_000

  @impl true
  def names, do: ["curl"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, %{help: true}} ->
        {Command.ok(help_text()), bash}

      {:ok, opts} ->
        case validate_network_access(bash, opts.url) do
          :ok ->
            perform_request(bash, opts)

          {:error, msg} ->
            {Command.error(msg), bash}
        end
    end
  end

  defp validate_network_access(bash, url) do
    network_config = Map.get(bash, :network, %{})
    enabled = Map.get(network_config, :enabled, false)
    allow_list = Map.get(network_config, :allow_list, [])

    cond do
      not enabled ->
        {:error, "curl: network access is disabled\n"}

      allow_list == [] ->
        :ok

      url_allowed?(url, allow_list) ->
        :ok

      true ->
        {:error, "curl: access to #{url} is not allowed\n"}
    end
  end

  defp url_allowed?(url, allow_list) do
    uri = URI.parse(url)
    host = uri.host || ""

    Enum.any?(allow_list, fn pattern ->
      pattern_matches?(pattern, host)
    end)
  end

  defp pattern_matches?("*", _host), do: true
  defp pattern_matches?("**", _host), do: true

  defp pattern_matches?("*." <> domain, host) do
    suffix = "." <> domain
    String.ends_with?(host, suffix) or host == domain
  end

  defp pattern_matches?(pattern, host), do: host == pattern

  defp perform_request(bash, opts) do
    client = bash.http_client || JustBash.HttpClient.Default

    request = %{
      method: opts.method,
      url: opts.url,
      headers: build_headers(opts),
      body: opts.data,
      timeout: opts.timeout,
      follow_redirects: opts.follow_redirects,
      insecure: opts.insecure
    }

    case client.request(request) do
      {:ok, response} ->
        handle_response(bash, response, opts)

      {:error, %{reason: reason}} ->
        msg = format_transport_error(reason)
        {Command.error("curl: #{msg}\n"), bash}
    end
  end

  defp build_headers(opts) do
    headers = opts.headers

    headers =
      if opts.user do
        encoded = Base.encode64(opts.user)
        Map.put(headers, "authorization", "Basic #{encoded}")
      else
        headers
      end

    headers =
      if opts.user_agent do
        Map.put(headers, "user-agent", opts.user_agent)
      else
        headers
      end

    headers
  end

  defp handle_response(bash, response, opts) do
    output = build_output(response, opts)
    write_output(bash, output, opts)
  end

  defp write_output(bash, output, %{output_file: nil}) do
    {Command.ok(output), bash}
  end

  defp write_output(bash, output, opts) do
    resolved = InMemoryFs.resolve_path(bash.cwd, opts.output_file)

    case InMemoryFs.write_file(bash.fs, resolved, output) do
      {:ok, new_fs} ->
        progress = if opts.silent, do: "", else: "  % Total    % Received\n"
        {Command.ok(progress), %{bash | fs: new_fs}}

      {:error, reason} ->
        {Command.error("curl: #{opts.output_file}: #{reason}\n"), bash}
    end
  end

  defp build_output(response, opts) do
    output = ""

    output =
      if opts.include_headers or opts.head_only do
        status_line = "HTTP/1.1 #{response.status} #{status_text(response.status)}\n"
        headers = format_response_headers(response.headers)
        output <> status_line <> headers <> "\n"
      else
        output
      end

    output =
      if opts.head_only do
        output
      else
        body =
          case response.body do
            nil -> ""
            b when is_binary(b) -> b
            other -> inspect(other)
          end

        output <> body
      end

    output
  end

  defp format_response_headers(headers) do
    Enum.map_join(headers, fn {k, v} -> "#{k}: #{v}\n" end)
  end

  defp status_text(200), do: "OK"
  defp status_text(201), do: "Created"
  defp status_text(204), do: "No Content"
  defp status_text(301), do: "Moved Permanently"
  defp status_text(302), do: "Found"
  defp status_text(304), do: "Not Modified"
  defp status_text(400), do: "Bad Request"
  defp status_text(401), do: "Unauthorized"
  defp status_text(403), do: "Forbidden"
  defp status_text(404), do: "Not Found"
  defp status_text(500), do: "Internal Server Error"
  defp status_text(502), do: "Bad Gateway"
  defp status_text(503), do: "Service Unavailable"
  defp status_text(_), do: "Unknown"

  defp format_transport_error(:timeout), do: "connection timed out"
  defp format_transport_error(:econnrefused), do: "connection refused"
  defp format_transport_error(:nxdomain), do: "could not resolve host"
  defp format_transport_error(reason), do: inspect(reason)

  defp parse_args(args) do
    parse_args(args, %{
      url: nil,
      method: :get,
      headers: %{},
      data: nil,
      output_file: nil,
      silent: false,
      include_headers: false,
      head_only: false,
      follow_redirects: false,
      insecure: false,
      user: nil,
      user_agent: nil,
      timeout: @default_timeout,
      help: false
    })
  end

  defp parse_args([], opts) do
    if opts.url == nil and not opts.help do
      {:error, "curl: no URL specified\n"}
    else
      {:ok, opts}
    end
  end

  defp parse_args(["--help" | _], opts), do: {:ok, %{opts | help: true}}
  defp parse_args(["-h" | _], opts), do: {:ok, %{opts | help: true}}

  defp parse_args(["-X", method | rest], opts) do
    parse_args(rest, %{opts | method: parse_method(method)})
  end

  defp parse_args(["--request", method | rest], opts) do
    parse_args(rest, %{opts | method: parse_method(method)})
  end

  defp parse_args(["-H", header | rest], opts) do
    case String.split(header, ":", parts: 2) do
      [key, value] ->
        key = String.trim(key) |> String.downcase()
        value = String.trim(value)
        parse_args(rest, %{opts | headers: Map.put(opts.headers, key, value)})

      _ ->
        {:error, "curl: invalid header: #{header}\n"}
    end
  end

  defp parse_args(["--header", header | rest], opts) do
    parse_args(["-H", header | rest], opts)
  end

  defp parse_args(["-d", data | rest], opts) do
    new_opts = %{opts | data: data, method: if(opts.method == :get, do: :post, else: opts.method)}
    parse_args(rest, new_opts)
  end

  defp parse_args(["--data", data | rest], opts), do: parse_args(["-d", data | rest], opts)
  defp parse_args(["--data-raw", data | rest], opts), do: parse_args(["-d", data | rest], opts)

  defp parse_args(["-o", file | rest], opts) do
    parse_args(rest, %{opts | output_file: file})
  end

  defp parse_args(["--output", file | rest], opts), do: parse_args(["-o", file | rest], opts)

  defp parse_args(["-s" | rest], opts), do: parse_args(rest, %{opts | silent: true})
  defp parse_args(["--silent" | rest], opts), do: parse_args(rest, %{opts | silent: true})

  defp parse_args(["-i" | rest], opts), do: parse_args(rest, %{opts | include_headers: true})

  defp parse_args(["--include" | rest], opts),
    do: parse_args(rest, %{opts | include_headers: true})

  defp parse_args(["-I" | rest], opts),
    do: parse_args(rest, %{opts | head_only: true, method: :head})

  defp parse_args(["--head" | rest], opts),
    do: parse_args(rest, %{opts | head_only: true, method: :head})

  defp parse_args(["-L" | rest], opts), do: parse_args(rest, %{opts | follow_redirects: true})

  defp parse_args(["--location" | rest], opts),
    do: parse_args(rest, %{opts | follow_redirects: true})

  defp parse_args(["-k" | rest], opts), do: parse_args(rest, %{opts | insecure: true})
  defp parse_args(["--insecure" | rest], opts), do: parse_args(rest, %{opts | insecure: true})

  defp parse_args(["-u", userpass | rest], opts) do
    parse_args(rest, %{opts | user: userpass})
  end

  defp parse_args(["--user", userpass | rest], opts),
    do: parse_args(["-u", userpass | rest], opts)

  defp parse_args(["-A", agent | rest], opts) do
    parse_args(rest, %{opts | user_agent: agent})
  end

  defp parse_args(["--user-agent", agent | rest], opts),
    do: parse_args(["-A", agent | rest], opts)

  defp parse_args(["--connect-timeout", seconds | rest], opts) do
    case Integer.parse(seconds) do
      {s, _} -> parse_args(rest, %{opts | timeout: s * 1000})
      :error -> parse_args(rest, opts)
    end
  end

  defp parse_args(["-m", seconds | rest], opts) do
    case Integer.parse(seconds) do
      {s, _} -> parse_args(rest, %{opts | timeout: s * 1000})
      :error -> parse_args(rest, opts)
    end
  end

  defp parse_args(["--max-time", seconds | rest], opts),
    do: parse_args(["-m", seconds | rest], opts)

  defp parse_args(["-" <> _ = flag | _rest], _opts) do
    {:error, "curl: unknown option: #{flag}\n"}
  end

  defp parse_args([url | rest], opts) do
    parse_args(rest, %{opts | url: url})
  end

  defp parse_method(method) do
    case String.upcase(method) do
      "GET" -> :get
      "POST" -> :post
      "PUT" -> :put
      "DELETE" -> :delete
      "PATCH" -> :patch
      "HEAD" -> :head
      "OPTIONS" -> :options
      _ -> :get
    end
  end

  defp help_text do
    """
    curl - transfer data from or to a server

    Usage: curl [OPTIONS] URL

    Options:
      -X, --request METHOD   HTTP method (GET, POST, PUT, DELETE, etc.)
      -H, --header HEADER    Add header (e.g., "Content-Type: application/json")
      -d, --data DATA        Send data in request body
      -o, --output FILE      Write output to file
      -s, --silent           Silent mode
      -i, --include          Include response headers in output
      -I, --head             Show headers only (HEAD request)
      -L, --location         Follow redirects
      -k, --insecure         Allow insecure connections
      -u, --user USER:PASS   Basic authentication
      -A, --user-agent STR   Set User-Agent header
      -m, --max-time SECS    Maximum time for request
          --connect-timeout  Connection timeout in seconds
      -h, --help             Show this help

    Network access must be enabled when creating the bash environment:
      JustBash.new(network: %{enabled: true})

    To restrict access to specific hosts:
      JustBash.new(network: %{enabled: true, allow_list: ["api.example.com", "*.github.com"]})
    """
  end
end
