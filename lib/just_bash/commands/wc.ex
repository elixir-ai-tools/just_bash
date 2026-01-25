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

        case InMemoryFs.read_file(bash.fs, resolved) do
          {:ok, content} ->
            output = format_output(content, file, flags)
            {Command.ok(output), bash}

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
    suffix = if file, do: " #{file}\n", else: "\n"
    format_counts(counts, flags) <> suffix
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

  defp format_counts(counts, %{l: true, w: false, c: false}), do: pad_count(counts.lines)
  defp format_counts(counts, %{l: false, w: true, c: false}), do: pad_count(counts.words)
  defp format_counts(counts, %{l: false, w: false, c: true}), do: pad_count(counts.bytes)

  # Default output: all three counts with consistent spacing
  # Real wc uses 8-character fields for each count (total 24 chars)
  defp format_counts(counts, _flags) do
    String.pad_leading(Integer.to_string(counts.lines), 8) <>
      String.pad_leading(Integer.to_string(counts.words), 8) <>
      String.pad_leading(Integer.to_string(counts.bytes), 8)
  end

  # Single count padding to 8 characters (standard wc format)
  defp pad_count(n), do: String.pad_leading(Integer.to_string(n), 8)

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
