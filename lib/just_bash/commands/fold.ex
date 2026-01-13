defmodule JustBash.Commands.Fold do
  @moduledoc "The `fold` command - wrap each input line to fit in specified width."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["fold"]

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

  defp get_content(_bash, %{files: []}, stdin), do: stdin

  defp get_content(bash, %{files: files}, _stdin) do
    case read_files(bash, files) do
      {:ok, data} -> data
      {:error, msg} -> {:error, msg}
    end
  end

  defp process_and_return(bash, {:error, msg}, _opts), do: {Command.error(msg), bash}

  defp process_and_return(bash, data, opts) do
    output = process_content(data, opts)
    {Command.ok(output), bash}
  end

  defp parse_args(args) do
    parse_args(args, %{width: 80, break_at_spaces: false, files: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-w", width | rest], opts) do
    case Integer.parse(width) do
      {w, ""} when w >= 1 -> parse_args(rest, %{opts | width: w})
      _ -> {:error, "fold: invalid number of columns: '#{width}'\n"}
    end
  end

  defp parse_args(["-w" <> width | rest], opts) when width != "" do
    case Integer.parse(width) do
      {w, ""} when w >= 1 -> parse_args(rest, %{opts | width: w})
      _ -> {:error, "fold: invalid number of columns: '#{width}'\n"}
    end
  end

  defp parse_args(["-s" | rest], opts) do
    parse_args(rest, %{opts | break_at_spaces: true})
  end

  defp parse_args(["-sw", width | rest], opts) do
    case Integer.parse(width) do
      {w, ""} when w >= 1 -> parse_args(rest, %{opts | width: w, break_at_spaces: true})
      _ -> {:error, "fold: invalid number of columns: '#{width}'\n"}
    end
  end

  defp parse_args(["-sw" <> width | rest], opts) when width != "" do
    case Integer.parse(width) do
      {w, ""} when w >= 1 -> parse_args(rest, %{opts | width: w, break_at_spaces: true})
      _ -> {:error, "fold: invalid number of columns: '#{width}'\n"}
    end
  end

  defp parse_args(["--" | rest], opts) do
    {:ok, %{opts | files: opts.files ++ rest}}
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "fold: invalid option '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp read_files(bash, files) do
    Enum.reduce_while(files, {:ok, ""}, fn file, {:ok, acc} ->
      resolved = InMemoryFs.resolve_path(bash.cwd, file)

      case InMemoryFs.read_file(bash.fs, resolved) do
        {:ok, data} -> {:cont, {:ok, acc <> data}}
        {:error, _} -> {:halt, {:error, "fold: #{file}: No such file or directory\n"}}
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

    folded = Enum.map(lines, &fold_line(&1, opts))
    output = Enum.join(folded, "\n")
    if has_trailing_newline, do: output <> "\n", else: output
  end

  defp fold_line("", _opts), do: ""

  defp fold_line(line, opts) do
    fold_line(String.graphemes(line), opts, [], "", 0, -1)
  end

  defp fold_line([], _opts, result, current, _col, _last_space) do
    final = if current != "", do: result ++ [current], else: result
    Enum.join(final, "\n")
  end

  defp fold_line([char | rest], opts, result, current, col, last_space) do
    char_width = 1
    new_col = col + char_width

    if new_col > opts.width and current != "" do
      if opts.break_at_spaces and last_space >= 0 do
        before = String.slice(current, 0, last_space + 1)
        after_space = String.slice(current, (last_space + 1)..-1//1)
        new_current = after_space <> char
        new_col = String.length(new_current)
        fold_line(rest, opts, result ++ [before], new_current, new_col, -1)
      else
        fold_line(rest, opts, result ++ [current], char, char_width, -1)
      end
    else
      new_last_space =
        if char == " " or char == "\t", do: String.length(current), else: last_space

      fold_line(rest, opts, result, current <> char, new_col, new_last_space)
    end
  end
end
