defmodule JustBash.Commands.Wc do
  @moduledoc "The `wc` command - print newline, word, and byte counts."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["wc"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, files} = parse_flags(args)

    case files do
      [file] ->
        resolved = InMemoryFs.resolve_path(bash.cwd, file)

        case InMemoryFs.read_file(bash, resolved) do
          {:ok, content, new_bash} ->
            output = format_output(content, file, flags)
            {Command.ok(output), new_bash}

          {:error, _} ->
            {Command.error("wc: #{file}: No such file or directory\n"), bash}
        end

      [] ->
        output = format_output(stdin, nil, flags)
        {Command.ok(output), bash}
    end
  end

  defp format_output(content, file, flags) do
    counts = count_content(content)

    formatted = format_counts(counts, flags, file != nil)

    if file do
      formatted <> " " <> file <> "\n"
    else
      formatted <> "\n"
    end
  end

  defp count_content(content) do
    # wc -l counts newline characters, not logical lines
    # "hello\n" = 1 line, "hello" = 0 lines
    lines = content |> String.graphemes() |> Enum.count(&(&1 == "\n"))

    %{
      lines: lines,
      words: length(String.split(content, ~r/\s+/, trim: true)),
      bytes: byte_size(content)
    }
  end

  defp format_counts(counts, %{l: true, w: false, c: false}, has_file?),
    do: format_single_count(counts.lines, has_file?)

  defp format_counts(counts, %{l: false, w: true, c: false}, has_file?),
    do: format_single_count(counts.words, has_file?)

  defp format_counts(counts, %{l: false, w: false, c: true}, has_file?),
    do: format_single_count(counts.bytes, has_file?)

  defp format_counts(counts, _flags, _has_file?) do
    # Match GNU wc formatting on Linux:
    # counts are printed as right-aligned 7-char fields, separated by a space.
    # Example: "      1       1       6"
    pad_field(counts.lines) <> " " <> pad_field(counts.words) <> " " <> pad_field(counts.bytes)
  end

  defp format_single_count(n, false), do: Integer.to_string(n)
  defp format_single_count(n, true), do: pad_field(n)

  defp pad_field(n), do: String.pad_leading(Integer.to_string(n), 7)

  defp parse_flags(args), do: parse_flags(args, %{l: false, w: false, c: false}, [])

  defp parse_flags(["-l" | rest], flags, files),
    do: parse_flags(rest, %{flags | l: true}, files)

  defp parse_flags(["-w" | rest], flags, files),
    do: parse_flags(rest, %{flags | w: true}, files)

  defp parse_flags(["-c" | rest], flags, files),
    do: parse_flags(rest, %{flags | c: true}, files)

  defp parse_flags([arg | rest], flags, files),
    do: parse_flags(rest, flags, files ++ [arg])

  defp parse_flags([], flags, files), do: {flags, files}
end
