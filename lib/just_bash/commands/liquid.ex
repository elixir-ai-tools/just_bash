defmodule JustBash.Commands.Liquid do
  @moduledoc """
  The `liquid` command - render Liquid templates.

  Uses the Solid library for Liquid template rendering.

  ## Examples

      # Render template with JSON data
      echo '{"name": "Alice"}' | liquid template.html

      # Render with inline template
      echo '{"name": "Alice"}' | liquid -e 'Hello, {{ name }}!'

      # Pipe JSON from sqlite/jq
      sqlite3 db "SELECT * FROM posts" --json | liquid templates/index.html

      # Use data from file
      liquid -d data.json template.html
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["liquid"]

  @impl true
  def execute(bash, args, stdin) do
    {:ok, opts} = parse_args(args)
    execute_with_opts(bash, opts, stdin)
  end

  defp execute_with_opts(bash, %{help: true}, _stdin) do
    help = """
    Usage: liquid [OPTIONS] [TEMPLATE_FILE]

    Render a Liquid template with JSON data.

    Options:
      -e, --eval TEMPLATE   Use inline template string instead of file
      -d, --data FILE       Read JSON data from file instead of stdin
      --strict              Error on undefined variables (default: empty string)
      --help                Show this help message

    Data is read as JSON from stdin (or -d file) and made available to the template.

    Examples:
      echo '{"name": "World"}' | liquid -e 'Hello, {{ name }}!'
      echo '{"users": [{"name": "Alice"}]}' | liquid template.html
      liquid -d data.json -e '{{ title }}'
      sqlite3 db "SELECT * FROM posts" --json | liquid index.html
    """

    {Command.ok(help), bash}
  end

  defp execute_with_opts(bash, opts, stdin) do
    with {:ok, template} <- get_template(bash, opts),
         {:ok, data} <- get_data(bash, opts, stdin),
         {:ok, output} <- render(template, data, opts) do
      {Command.ok(output), bash}
    else
      {:error, msg} ->
        {Command.error("liquid: #{msg}\n"), bash}
    end
  end

  defp get_template(_bash, %{eval: template}) when is_binary(template) do
    {:ok, template}
  end

  defp get_template(bash, %{template_file: file}) when is_binary(file) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, "cannot read template '#{file}'"}
    end
  end

  defp get_template(_bash, _opts) do
    {:error, "no template specified (use -e or provide a template file)"}
  end

  defp get_data(bash, %{data_file: file}, _stdin) when is_binary(file) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, content} -> parse_json(content)
      {:error, _} -> {:error, "cannot read data file '#{file}'"}
    end
  end

  defp get_data(_bash, _opts, stdin) do
    stdin = String.trim(stdin)

    if stdin == "" do
      {:ok, %{}}
    else
      parse_json(stdin)
    end
  end

  defp parse_json(content) do
    case Jason.decode(content) do
      {:ok, data} -> {:ok, normalize_data(data)}
      {:error, _} -> {:error, "invalid JSON data"}
    end
  end

  # Convert string keys to atoms for Solid, and handle arrays
  defp normalize_data(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {to_string(k), normalize_data(v)} end)
  end

  defp normalize_data(data) when is_list(data) do
    Enum.map(data, &normalize_data/1)
  end

  defp normalize_data(data), do: data

  @dialyzer {:nowarn_function, render: 3}
  defp render(template, data, opts) do
    parse_opts = if opts.strict, do: [strict_variables: true], else: []

    case Solid.parse(template, parse_opts) do
      {:ok, parsed} ->
        case Solid.render(parsed, data) do
          {:ok, result, _} ->
            {:ok, IO.iodata_to_binary(result)}

          {:error, errors, _} ->
            {:error, "render error: #{inspect(errors)}"}
        end

      {:error, %Solid.TemplateError{} = error} ->
        {:error, "template error: #{Exception.message(error)}"}

      {:error, error} ->
        {:error, "parse error: #{inspect(error)}"}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{
      template_file: nil,
      eval: nil,
      data_file: nil,
      strict: false,
      help: false
    })
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["--help" | _], opts), do: {:ok, %{opts | help: true}}
  defp parse_args(["-h" | _], opts), do: {:ok, %{opts | help: true}}

  defp parse_args(["--eval", template | rest], opts) do
    parse_args(rest, %{opts | eval: template})
  end

  defp parse_args(["-e", template | rest], opts) do
    parse_args(rest, %{opts | eval: template})
  end

  defp parse_args(["--data", file | rest], opts) do
    parse_args(rest, %{opts | data_file: file})
  end

  defp parse_args(["-d", file | rest], opts) do
    parse_args(rest, %{opts | data_file: file})
  end

  defp parse_args(["--strict" | rest], opts) do
    parse_args(rest, %{opts | strict: true})
  end

  defp parse_args(["-e" <> template | rest], opts) when template != "" do
    parse_args(rest, %{opts | eval: template})
  end

  defp parse_args(["-d" <> file | rest], opts) when file != "" do
    parse_args(rest, %{opts | data_file: file})
  end

  defp parse_args([arg | rest], %{template_file: nil} = opts) do
    parse_args(rest, %{opts | template_file: arg})
  end

  defp parse_args([_arg | rest], opts) do
    # Ignore extra args
    parse_args(rest, opts)
  end
end
