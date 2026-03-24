defmodule JustBash.Commands.Wget do
  @moduledoc """
  The `wget` command - non-interactive network downloader.

  Supports:
  - GET requests to download files
  - `-O file` / `--output-document=file` to save output
  - `-q` / `--quiet` for silent mode
  - `-O -` to write to stdout

  Uses the same HTTP client and network configuration as `curl`.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs
  alias JustBash.Limits
  alias JustBash.Network

  @impl true
  def names, do: ["wget"]

  @impl true
  def execute(bash, args, _stdin) do
    {opts, urls} = parse_args(args)

    cond do
      opts.help ->
        {Command.ok(help_text()), bash}

      urls == [] ->
        {Command.error("wget: missing URL\n"), bash}

      true ->
        url = List.first(urls)

        case Network.validate_access(bash, url, "wget") do
          :ok -> perform_request(bash, url, %{opts | url: url})
          {:error, msg} -> {Command.error(msg), bash}
        end
    end
  end

  defp parse_args(args) do
    parse_args(args, %{output: nil, quiet: false, help: false, url: nil}, [])
  end

  defp parse_args([], opts, urls), do: {opts, Enum.reverse(urls)}

  defp parse_args(["-O", file | rest], opts, urls),
    do: parse_args(rest, %{opts | output: file}, urls)

  defp parse_args(["--output-document=" <> file | rest], opts, urls),
    do: parse_args(rest, %{opts | output: file}, urls)

  defp parse_args(["-q" | rest], opts, urls),
    do: parse_args(rest, %{opts | quiet: true}, urls)

  defp parse_args(["--quiet" | rest], opts, urls),
    do: parse_args(rest, %{opts | quiet: true}, urls)

  defp parse_args(["-h" | rest], opts, urls),
    do: parse_args(rest, %{opts | help: true}, urls)

  defp parse_args(["--help" | rest], opts, urls),
    do: parse_args(rest, %{opts | help: true}, urls)

  # Skip other flags silently (e.g. --no-check-certificate)
  defp parse_args(["--" <> _ | rest], opts, urls),
    do: parse_args(rest, opts, urls)

  defp parse_args(["-" <> _ | rest], opts, urls),
    do: parse_args(rest, opts, urls)

  defp parse_args([url | rest], opts, urls),
    do: parse_args(rest, opts, [url | urls])

  defp perform_request(bash, url, opts) do
    client = bash.http_client || JustBash.HttpClient.Default

    request = %{
      method: :get,
      url: url,
      headers: %{},
      body: nil,
      timeout: 30_000,
      follow_redirects: false,
      insecure: false
    }

    # wget always follows redirects and only issues GET requests,
    # so the default on_redirect (identity) is correct.
    case Network.follow_redirects(bash, request, "wget", &client.request/1) do
      {:response, response} ->
        handle_response(bash, response, opts)

      {:error, %{reason: msg}} when is_binary(msg) ->
        {Command.error(msg), bash}

      {:error, %{reason: reason}} ->
        {Command.error("wget: failed to connect: #{inspect(reason)}\n"), bash}
    end
  end

  defp handle_response(bash, %{status: status}, _opts) when status >= 400 do
    {Command.error("wget: server returned HTTP #{status}\n"), bash}
  end

  defp handle_response(bash, response, %{output: "-"}) do
    case Limits.enforce_http_body(bash, "wget", response.body) do
      {:ok, body} -> {Command.ok(body), bash}
      {:error, result, new_bash} -> {result, new_bash}
    end
  end

  defp handle_response(bash, response, %{output: nil, url: url} = opts) do
    case Limits.enforce_http_body(bash, "wget", response.body) do
      {:ok, body} ->
        response = %{response | body: body}
        uri = URI.parse(url)
        filename = Path.basename(uri.path || "index.html")
        filename = if filename == "", do: "index.html", else: filename
        write_to_file(bash, response, filename, opts)

      {:error, result, new_bash} ->
        {result, new_bash}
    end
  end

  defp handle_response(bash, response, opts) do
    case Limits.enforce_http_body(bash, "wget", response.body) do
      {:ok, body} -> write_to_file(bash, %{response | body: body}, opts.output, opts)
      {:error, result, new_bash} -> {result, new_bash}
    end
  end

  defp write_to_file(bash, response, filename, opts) do
    body = response.body
    resolved = InMemoryFs.resolve_path(bash.cwd, filename)

    case Limits.write_file(bash, resolved, body) do
      {:ok, new_bash} ->
        progress = if opts.quiet, do: "", else: "Saving to: '#{filename}'\n"
        {Command.ok(progress), new_bash}

      {:error, reason, new_bash} ->
        {Command.error(Limits.command_write_error("wget", filename, reason)), new_bash}
    end
  end

  defp help_text do
    """
    wget - non-interactive network downloader

    Usage: wget [OPTIONS] URL

    Options:
      -O, --output-document=FILE   Save content to FILE (use - for stdout)
      -q, --quiet                  Quiet mode
      -h, --help                   Show this help
    """
  end
end
