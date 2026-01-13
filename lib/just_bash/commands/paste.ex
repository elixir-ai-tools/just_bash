defmodule JustBash.Commands.Paste do
  @moduledoc "The `paste` command - merge lines of files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["paste"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        if opts.files == [] do
          {Command.error("usage: paste [-s] [-d delimiters] file ...\n"), bash}
        else
          case read_all_files(bash, opts.files, stdin) do
            {:error, msg} ->
              {Command.error(msg), bash}

            {:ok, file_contents} ->
              output =
                if opts.serial do
                  process_serial(file_contents, opts.delimiter)
                else
                  process_parallel(file_contents, opts.delimiter)
                end

              {Command.ok(output), bash}
          end
        end
    end
  end

  defp parse_args(args) do
    parse_args(args, %{delimiter: "\t", serial: false, files: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-d", delim | rest], opts) do
    parse_args(rest, %{opts | delimiter: delim})
  end

  defp parse_args(["-d" <> delim | rest], opts) when delim != "" do
    parse_args(rest, %{opts | delimiter: delim})
  end

  defp parse_args(["--delimiters=" <> delim | rest], opts) do
    parse_args(rest, %{opts | delimiter: delim})
  end

  defp parse_args(["-s" | rest], opts) do
    parse_args(rest, %{opts | serial: true})
  end

  defp parse_args(["--serial" | rest], opts) do
    parse_args(rest, %{opts | serial: true})
  end

  defp parse_args(["-sd" <> delim | rest], opts) when delim != "" do
    parse_args(rest, %{opts | serial: true, delimiter: delim})
  end

  defp parse_args(["-sd", delim | rest], opts) do
    parse_args(rest, %{opts | serial: true, delimiter: delim})
  end

  defp parse_args(["--" <> _ = arg | _rest], _opts) do
    {:error, "paste: unrecognized option '#{arg}'\n"}
  end

  defp parse_args(["-" <> <<c::utf8>> | _rest], _opts) when c != ?d and c != ?s do
    {:error, "paste: invalid option -- '#{<<c::utf8>>}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp read_all_files(bash, files, stdin) do
    stdin_lines = split_lines(stdin)
    stdin_count = Enum.count(files, &(&1 == "-"))

    {result, _stdin_idx} =
      Enum.reduce_while(files, {{:ok, []}, 0}, fn file, {{:ok, acc}, stdin_idx} ->
        case read_file_lines(bash, file, stdin_lines, stdin_count, stdin_idx) do
          {:ok, lines, new_stdin_idx} ->
            {:cont, {{:ok, acc ++ [lines]}, new_stdin_idx}}

          {:error, msg} ->
            {:halt, {{:error, msg}, stdin_idx}}
        end
      end)

    result
  end

  defp read_file_lines(_bash, "-", stdin_lines, stdin_count, stdin_idx) do
    lines =
      stdin_lines
      |> Enum.drop(stdin_idx)
      |> Enum.take_every(stdin_count)

    {:ok, lines, stdin_idx + 1}
  end

  defp read_file_lines(bash, file, _stdin_lines, _stdin_count, stdin_idx) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, content} ->
        {:ok, split_lines(content), stdin_idx}

      {:error, _} ->
        {:error, "paste: #{file}: No such file or directory\n"}
    end
  end

  defp split_lines(content) do
    lines = String.split(content, "\n", trim: false)

    if List.last(lines) == "" do
      List.delete_at(lines, -1)
    else
      lines
    end
  end

  defp process_serial(file_contents, delimiter) do
    file_contents
    |> Enum.map_join(fn lines ->
      join_with_delimiters(lines, delimiter) <> "\n"
    end)
  end

  defp process_parallel(file_contents, delimiter) do
    max_lines = file_contents |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    Enum.map_join(0..(max_lines - 1), fn idx ->
      parts = Enum.map(file_contents, fn lines -> Enum.at(lines, idx, "") end)
      join_with_delimiters(parts, delimiter) <> "\n"
    end)
  end

  defp join_with_delimiters([], _delimiters), do: ""
  defp join_with_delimiters([single], _delimiters), do: single

  defp join_with_delimiters(parts, delimiters) do
    delim_chars = String.graphemes(delimiters)

    parts
    |> Enum.with_index()
    |> Enum.map_join(fn {part, idx} ->
      if idx == 0 do
        part
      else
        delim_idx = rem(idx - 1, length(delim_chars))
        Enum.at(delim_chars, delim_idx) <> part
      end
    end)
  end
end
