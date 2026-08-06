defmodule JustBash.Commands.Expand do
  @moduledoc "The `expand` command - convert tabs to spaces."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FS

  @impl true
  def names, do: ["expand"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        execute_with_opts(bash, opts, stdin)
    end
  end

  defp execute_with_opts(bash, opts, stdin) do
    content = get_content(bash, opts, stdin)
    process_and_return(bash, content, opts)
  end

  defp get_content(bash, %{files: []}, stdin), do: {:ok, stdin, bash.fs}

  defp get_content(bash, %{files: files}, stdin) do
    read_files(bash, files, stdin)
  end

  defp process_and_return(bash, {:error, msg}, _opts), do: {Command.error(msg), bash}

  defp process_and_return(bash, {:ok, data, fs}, opts) do
    output = process_content(data, opts)
    {Command.ok(output), %{bash | fs: fs}}
  end

  defp parse_args(args) do
    parse_args(args, %{tab_stops: [8], leading_only: false, files: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-t", spec | rest], opts) do
    case parse_tab_stops(spec) do
      {:ok, stops} -> parse_args(rest, %{opts | tab_stops: stops})
      {:error, _} -> {:error, "expand: invalid tab size: '#{spec}'\n"}
    end
  end

  defp parse_args(["-t" <> spec | rest], opts) when spec != "" do
    case parse_tab_stops(spec) do
      {:ok, stops} -> parse_args(rest, %{opts | tab_stops: stops})
      {:error, _} -> {:error, "expand: invalid tab size: '#{spec}'\n"}
    end
  end

  defp parse_args(["--tabs=" <> spec | rest], opts) do
    case parse_tab_stops(spec) do
      {:ok, stops} -> parse_args(rest, %{opts | tab_stops: stops})
      {:error, _} -> {:error, "expand: invalid tab size: '#{spec}'\n"}
    end
  end

  defp parse_args(["-i" | rest], opts) do
    parse_args(rest, %{opts | leading_only: true})
  end

  defp parse_args(["--initial" | rest], opts) do
    parse_args(rest, %{opts | leading_only: true})
  end

  defp parse_args(["--" | rest], opts) do
    {:ok, %{opts | files: opts.files ++ rest}}
  end

  # A bare `-` is never a flag: POSIX reads it as the stdin operand.
  defp parse_args(["-" | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ ["-"]})
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "expand: invalid option '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp parse_tab_stops(spec) do
    parts = String.split(spec, ",")

    stops =
      Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
        case Integer.parse(String.trim(part)) do
          {n, ""} when n >= 1 -> {:cont, {:ok, acc ++ [n]}}
          _ -> {:halt, {:error, :invalid}}
        end
      end)

    case stops do
      {:ok, list} when length(list) > 1 ->
        if Enum.sort(list) == list and list == Enum.uniq(list) do
          {:ok, list}
        else
          {:error, :invalid}
        end

      {:ok, list} ->
        {:ok, list}

      {:error, _} ->
        {:error, :invalid}
    end
  end

  defp read_files(bash, files, stdin) do
    Enum.reduce_while(files, {:ok, "", bash.fs}, fn file, {:ok, acc, fs} ->
      case StdinOperand.read(fs, bash.cwd, file, stdin) do
        {:ok, data, fs} -> {:cont, {:ok, acc <> data, fs}}
        {:error, error} -> {:halt, {:error, "expand: #{file}: #{FS.strerror(error)}\n"}}
      end
    end)
  end

  defp process_content("", _opts), do: ""

  defp process_content(content, opts) do
    has_trailing_newline = String.ends_with?(content, "\n")
    lines = String.split(content, "\n", trim: false)

    lines =
      if has_trailing_newline and List.last(lines) == "" do
        List.delete_at(lines, -1)
      else
        lines
      end

    expanded = Enum.map(lines, &expand_line(&1, opts))
    output = Enum.join(expanded, "\n")
    if has_trailing_newline, do: output <> "\n", else: output
  end

  defp expand_line(line, opts) do
    expand_chars(String.graphemes(line), opts, 0, true, [])
    |> Enum.reverse()
    |> Enum.join()
  end

  defp expand_chars([], _opts, _col, _leading, acc), do: acc

  defp expand_chars(["\t" | rest], opts, col, leading, acc) do
    if opts.leading_only and not leading do
      expand_chars(rest, opts, col + 1, false, ["\t" | acc])
    else
      spaces = get_tab_width(col, opts.tab_stops)
      expand_chars(rest, opts, col + spaces, leading, [String.duplicate(" ", spaces) | acc])
    end
  end

  defp expand_chars([char | rest], opts, col, leading, acc) do
    new_leading = leading and (char == " " or char == "\t")
    expand_chars(rest, opts, col + 1, new_leading, [char | acc])
  end

  defp get_tab_width(col, [single]) do
    single - rem(col, single)
  end

  defp get_tab_width(col, stops) do
    case Enum.find(stops, fn stop -> stop > col end) do
      nil ->
        if length(stops) >= 2 do
          last_interval = Enum.at(stops, -1) - Enum.at(stops, -2)
          last_stop = Enum.at(stops, -1)
          stops_after = div(col - last_stop, last_interval) + 1
          next_stop = last_stop + stops_after * last_interval
          next_stop - col
        else
          1
        end

      stop ->
        stop - col
    end
  end
end
