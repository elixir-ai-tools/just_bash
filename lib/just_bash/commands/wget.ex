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

        case validate_network_access(bash, url) do
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

  defp validate_network_access(bash, url) do
    network_config = Map.get(bash, :network, %{})
    enabled = Map.get(network_config, :enabled, false)
    allow_list = Map.get(network_config, :allow_list, [])

    cond do
      not enabled ->
        {:error, "wget: network access is disabled\n"}

      allow_list == [] ->
        :ok

      url_allowed?(url, allow_list) ->
        :ok

      true ->
        {:error, "wget: access to #{url} is not allowed\n"}
    end
  end

  defp url_allowed?(url, allow_list) do
    uri = URI.parse(url)
    host = uri.host || ""

    Enum.any?(allow_list, fn pattern ->
      case pattern do
        "*" -> true
        "**" -> true
        "*." <> domain -> String.ends_with?(host, "." <> domain) or host == domain
        ^host -> true
        _ -> false
      end
    end)
  end

  defp perform_request(bash, url, opts) do
    client = bash.http_client || JustBash.HttpClient.Default

    request = %{
      method: :get,
      url: url,
      headers: %{},
      body: nil,
      timeout: 30_000,
      follow_redirects: true,
      insecure: false
    }

    case client.request(request) do
      {:ok, response} ->
        handle_response(bash, response, opts)

      {:error, %{reason: reason}} ->
        {Command.error("wget: failed to connect: #{inspect(reason)}\n"), bash}
    end
  end

  defp handle_response(bash, %{status: status}, _opts) when status >= 400 do
    {Command.error("wget: server returned HTTP #{status}\n"), bash}
  end

  defp handle_response(bash, response, %{output: "-"}) do
    body = response.body || ""
    {Command.ok(body), bash}
  end

  defp handle_response(bash, response, %{output: nil, url: url} = opts) do
    # Default: derive filename from URL or use index.html
    uri = URI.parse(url || "")
    filename = Path.basename(uri.path || "index.html")
    filename = if filename == "", do: "index.html", else: filename
    write_to_file(bash, response, filename, opts)
  end

  defp handle_response(bash, response, opts) do
    write_to_file(bash, response, opts.output, opts)
  end

  defp write_to_file(bash, response, filename, opts) do
    body = response.body || ""
    resolved = InMemoryFs.resolve_path(bash.cwd, filename)

    case InMemoryFs.write_file(bash.fs, resolved, body) do
      {:ok, new_fs} ->
        progress = if opts.quiet, do: "", else: "Saving to: '#{filename}'\n"
        {Command.ok(progress), %{bash | fs: new_fs}}

      {:error, reason} ->
        {Command.error("wget: #{filename}: #{reason}\n"), bash}
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
