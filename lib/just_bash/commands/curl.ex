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
  alias JustBash.Limits
  alias JustBash.Network

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
            case Network.validate_access(bash, opts.url, "curl") do
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
      show_error: [short: "-S", long: "--show-error", type: :boolean],
      fail_on_error: [short: "-f", long: "--fail", type: :boolean],
      include_headers: [short: "-i", long: "--include", type: :boolean],
      head_only: [short: "-I", long: "--head", type: :boolean],
      follow_redirects: [short: "-L", long: "--location", type: :boolean],
      user: [short: "-u", long: "--user", type: :string],
      user_agent: [short: "-A", long: "--user-agent", type: :string],
      timeout: [short: "-m", long: "--max-time", type: :integer, default: @default_timeout],
      connect_timeout: [long: "--connect-timeout", type: :integer]
    ]
  end

  defp perform_request(bash, opts) do
    client = bash.http_client || JustBash.HttpClient.Default

    request = %{
      method: opts.method,
      url: opts.url,
      headers: build_headers(opts),
      body: opts.data,
      timeout: opts.timeout,
      # Always disable library-level redirect following — we handle it
      # manually so every redirect target is checked against the allow_list.
      follow_redirects: false,
      insecure: false
    }

    request_fn = &client.request/1

    on_redirect = fn status, req ->
      %{req | method: redirect_method(status, req.method)}
    end

    case Network.follow_redirects(bash, request, "curl", request_fn, on_redirect) do
      {:response, response} ->
        handle_response(bash, response, opts)

      {:error, %{reason: msg}} when is_binary(msg) ->
        {Command.error(msg), bash}

      {:error, %{reason: reason}} ->
        {Command.error("curl: #{format_transport_error(reason)}\n"), bash}
    end
  end

  # 303 always becomes GET; 307/308 preserve method; 301/302 conventionally become GET
  defp redirect_method(303, _), do: :get
  defp redirect_method(status, method) when status in [307, 308], do: method
  defp redirect_method(_, _), do: :get

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
    case Limits.enforce_http_body(bash, "curl", response.body) do
      {:ok, body} ->
        output = build_output(%{response | body: body}, opts)
        write_output(bash, output, opts)

      {:error, result, new_bash} ->
        {result, new_bash}
    end
  end

  defp write_output(bash, output, %{output_file: nil}) do
    {Command.ok(output), bash}
  end

  defp write_output(bash, output, opts) do
    resolved = InMemoryFs.resolve_path(bash.cwd, opts.output_file)

    case Limits.write_file(bash, resolved, output) do
      {:ok, new_bash} ->
        progress = if opts.silent, do: "", else: "  % Total    % Received\n"
        {Command.ok(progress), new_bash}

      {:error, reason, new_bash} ->
        {Command.error(Limits.command_write_error("curl", opts.output_file, reason)), new_bash}
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
        output <> response.body
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
      -u, --user USER:PASS   Basic authentication
      -A, --user-agent STR   Set User-Agent header
      -m, --max-time SECS    Maximum time for request
          --connect-timeout  Connection timeout in seconds
      -h, --help             Show this help

    Network access must be enabled when creating the bash environment:
      JustBash.new(network: %{enabled: true, allow_list: :all})

    To restrict access to specific hosts:
      JustBash.new(network: %{enabled: true, allow_list: ["api.example.com", "*.github.com"]})
    """
  end
end
