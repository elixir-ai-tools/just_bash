defmodule JustBash.Commands.Jq do
  @moduledoc """
  The `jq` command - command-line JSON processor.

  Supports:
  - Identity filter (.)
  - Object index (.foo, .foo.bar)
  - Array index (.[0], .[-1])
  - Array slice (.[2:5])
  - Array/Object iterator (.[], .foo[])
  - Pipe operator (|)
  - Optional operator (.foo?)
  - Multiple outputs (,)
  - Object construction ({a: .b})
  - Array construction ([.foo, .bar])
  - Comparison and boolean operators (==, !=, <, >, and, or, not)
  - Built-in functions: keys, values, length, type, has, in, map, select, empty,
    add, first, last, nth, flatten, reverse, sort, sort_by, unique, unique_by,
    group_by, min, max, min_by, max_by, contains, inside, split, join,
    ascii_downcase, ascii_upcase, ltrimstr, rtrimstr, startswith, endswith,
    tostring, tonumber, tojson, fromjson
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.Jq.{Parser, Evaluator}
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["jq"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, %{help: true}} ->
        {Command.ok(help_text()), bash}

      {:ok, opts} ->
        input = get_input(bash, opts, stdin)

        case input do
          {:error, msg} ->
            {Command.error(msg), bash}

          {:ok, json_input} ->
            process_jq(json_input, opts)
            |> case do
              {:ok, output} -> {Command.ok(output), bash}
              {:error, msg} -> {Command.error(msg), bash}
            end
        end
    end
  end

  defp get_input(bash, opts, stdin) do
    cond do
      opts.null_input ->
        {:ok, nil}

      opts.file ->
        resolved = InMemoryFs.resolve_path(bash.cwd, opts.file)

        case InMemoryFs.read_file(bash.fs, resolved) do
          {:ok, content} -> {:ok, content}
          {:error, _} -> {:error, "jq: #{opts.file}: No such file or directory\n"}
        end

      true ->
        {:ok, stdin}
    end
  end

  defp process_jq(input, opts) do
    case Parser.parse(opts.filter) do
      {:error, msg} ->
        {:error, "jq: #{msg}\n"}

      {:ok, ast} ->
        parsed_input = parse_input(input, opts)

        case parsed_input do
          {:error, msg} ->
            {:error, msg}

          {:ok, data} ->
            case Evaluator.evaluate(ast, data, opts) do
              {:ok, results} ->
                output = format_output(results, opts)
                {:ok, output}

              {:error, msg} ->
                {:error, "jq: #{msg}\n"}
            end
        end
    end
  end

  defp parse_input(nil, _opts), do: {:ok, nil}
  defp parse_input("", _opts), do: {:ok, nil}

  defp parse_input(input, opts) do
    input = String.trim(input)

    if input == "" do
      {:ok, nil}
    else
      if opts.slurp do
        parse_slurp_input(input)
      else
        case Jason.decode(input) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "jq: parse error: Invalid JSON\n"}
        end
      end
    end
  end

  defp parse_slurp_input(input) do
    lines =
      input
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 != ""))

    results =
      Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
        case Jason.decode(line) do
          {:ok, data} -> {:cont, {:ok, acc ++ [data]}}
          {:error, _} -> {:halt, {:error, "jq: parse error: Invalid JSON\n"}}
        end
      end)

    case results do
      {:ok, list} -> {:ok, list}
      error -> error
    end
  end

  defp format_output(results, opts) do
    separator = if opts.join_output, do: "", else: "\n"

    results
    |> Enum.map_join(separator, &format_value(&1, opts))
    |> then(fn s -> if opts.join_output, do: s, else: s <> "\n" end)
  end

  defp format_value(value, opts) do
    cond do
      opts.raw_output and is_binary(value) ->
        value

      opts.compact ->
        Jason.encode!(value)

      opts.tab ->
        Jason.encode!(value, pretty: true)
        |> String.replace("  ", "\t")

      true ->
        Jason.encode!(value, pretty: true)
    end
  end

  defp parse_args(args), do: parse_args(args, default_opts())

  defp default_opts do
    %{
      filter: ".",
      file: nil,
      raw_output: false,
      compact: false,
      exit_status: false,
      slurp: false,
      null_input: false,
      join_output: false,
      sort_keys: false,
      tab: false,
      help: false
    }
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["--help" | _], opts), do: {:ok, %{opts | help: true}}

  defp parse_args(["-r" | rest], opts), do: parse_args(rest, %{opts | raw_output: true})
  defp parse_args(["--raw-output" | rest], opts), do: parse_args(rest, %{opts | raw_output: true})

  defp parse_args(["-c" | rest], opts), do: parse_args(rest, %{opts | compact: true})

  defp parse_args(["--compact-output" | rest], opts),
    do: parse_args(rest, %{opts | compact: true})

  defp parse_args(["-e" | rest], opts), do: parse_args(rest, %{opts | exit_status: true})

  defp parse_args(["--exit-status" | rest], opts),
    do: parse_args(rest, %{opts | exit_status: true})

  defp parse_args(["-s" | rest], opts), do: parse_args(rest, %{opts | slurp: true})
  defp parse_args(["--slurp" | rest], opts), do: parse_args(rest, %{opts | slurp: true})

  defp parse_args(["-n" | rest], opts), do: parse_args(rest, %{opts | null_input: true})
  defp parse_args(["--null-input" | rest], opts), do: parse_args(rest, %{opts | null_input: true})

  defp parse_args(["-j" | rest], opts), do: parse_args(rest, %{opts | join_output: true})

  defp parse_args(["--join-output" | rest], opts),
    do: parse_args(rest, %{opts | join_output: true})

  defp parse_args(["-S" | rest], opts), do: parse_args(rest, %{opts | sort_keys: true})
  defp parse_args(["--sort-keys" | rest], opts), do: parse_args(rest, %{opts | sort_keys: true})

  defp parse_args(["--tab" | rest], opts), do: parse_args(rest, %{opts | tab: true})

  defp parse_args(["-C" | rest], opts), do: parse_args(rest, opts)
  defp parse_args(["--color-output" | rest], opts), do: parse_args(rest, opts)
  defp parse_args(["-M" | rest], opts), do: parse_args(rest, opts)
  defp parse_args(["--monochrome-output" | rest], opts), do: parse_args(rest, opts)

  defp parse_args(["-" <> _ = flag | _rest], _opts) do
    {:error, "jq: Unknown option: #{flag}\n"}
  end

  defp parse_args([filter | rest], opts) do
    if opts.filter == "." do
      case rest do
        [file] -> {:ok, %{opts | filter: filter, file: file}}
        [] -> {:ok, %{opts | filter: filter}}
        _ -> {:error, "jq: too many arguments\n"}
      end
    else
      {:ok, %{opts | file: filter}}
    end
  end

  defp help_text do
    """
    jq - command-line JSON processor

    Usage: jq [OPTIONS] FILTER [FILE]

    Options:
      -r, --raw-output     output strings without quotes
      -c, --compact-output compact output (no pretty printing)
      -e, --exit-status    set exit status based on output
      -s, --slurp          read entire input into array
      -n, --null-input     don't read any input
      -j, --join-output    don't print newlines after each output
      -S, --sort-keys      sort object keys
          --tab            use tabs for indentation
          --help           display this help and exit

    Filter Syntax:
      .                    identity (return input unchanged)
      .foo                 object field access
      .foo.bar             nested field access
      .[0]                 array index
      .[]                  iterate array/object values
      .foo[]               iterate field values
      select(expr)         filter by condition
      map(expr)            transform each element
      keys, values         object keys/values
      length               array/string/object length
      type                 type of value
      sort, reverse        array operations
      first, last          first/last element
      add                  sum/concatenate values
      unique               remove duplicates
      split(s), join(s)    string operations
      | (pipe)             chain filters
      , (comma)            multiple outputs

    Examples:
      jq '.name' file.json
      jq '.users[0].email' data.json
      jq '.[] | select(.active)' users.json
      echo '{"a":1}' | jq '.a'
    """
  end
end
