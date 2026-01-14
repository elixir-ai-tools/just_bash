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

  alias JustBash.Commands.ArgParser
  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @default_timeout 30_000

  @impl true
  def names, do: ["curl"]

  @impl true
  def execute(bash, args, _stdin) do
    case ArgParser.parse(args, flags(), command: "curl") do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts, positional} ->
        opts = finalize_opts(opts, positional)

        cond do
          opts.help ->
            {Command.ok(help_text()), bash}

          opts.url == nil ->
            {Command.error("curl: no URL specified\n"), bash}

          true ->
            case validate_network_access(bash, opts.url) do
              :ok -> perform_request(bash, opts)
              {:error, msg} -> {Command.error(msg), bash}
            end
        end
    end
  end

  # Post-process parsed options
  defp finalize_opts(opts, positional) do
    opts
    |> Map.put(:url, List.first(positional))
    |> Map.put(:headers, parse_headers(opts.header))
    |> Map.put(:data, opts.data || opts[:data_raw])
    |> Map.update!(:method, &parse_method/1)
    |> apply_head_only()
    |> apply_data_method()
    |> apply_timeout()
  end

  defp parse_headers(header_list) do
    Enum.reduce(header_list, %{}, fn header, acc ->
      case String.split(header, ":", parts: 2) do
        [key, value] ->
          key = String.trim(key) |> String.downcase()
          value = String.trim(value)
          Map.put(acc, key, value)

        _ ->
          acc
      end
    end)
  end

  defp apply_head_only(%{head_only: true} = opts), do: %{opts | method: :head}
  defp apply_head_only(opts), do: opts

  defp apply_data_method(%{data: data, method: :get} = opts) when not is_nil(data) do
    %{opts | method: :post}
  end

  defp apply_data_method(opts), do: opts

  defp apply_timeout(%{connect_timeout: ct} = opts) when is_integer(ct) do
    %{opts | timeout: ct * 1000}
  end

  defp apply_timeout(%{timeout: t} = opts) when is_integer(t) do
    %{opts | timeout: t * 1000}
  end

  defp apply_timeout(opts), do: opts

  defp parse_method(method) when is_atom(method), do: method

  defp parse_method(method) when is_binary(method) do
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

  # Declarative flag specification
  defp flags do
    [
      help: [short: "-h", long: "--help", type: :boolean],
      method: [short: "-X", long: "--request", type: :string, default: "GET"],
      header: [short: "-H", long: "--header", type: :accumulator, default: []],
      data: [short: "-d", long: "--data", type: :string],
      data_raw: [long: "--data-raw", type: :string],
      output_file: [short: "-o", long: "--output", type: :string],
      silent: [short: "-s", long: "--silent", type: :boolean],
      include_headers: [short: "-i", long: "--include", type: :boolean],
      head_only: [short: "-I", long: "--head", type: :boolean],
      follow_redirects: [short: "-L", long: "--location", type: :boolean],
      insecure: [short: "-k", long: "--insecure", type: :boolean],
      user: [short: "-u", long: "--user", type: :string],
      user_agent: [short: "-A", long: "--user-agent", type: :string],
      timeout: [short: "-m", long: "--max-time", type: :integer, default: @default_timeout],
      connect_timeout: [long: "--connect-timeout", type: :integer]
    ]
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
