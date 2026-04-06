defmodule JustBash.Commands.Wc do
  @moduledoc "The `wc` command - print newline, word, and byte counts."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @short_flags %{?l => :l, ?w => :w, ?c => :c}

  @impl true
  def names, do: ["wc"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, files} = parse_flags(args)

    case files do
      [] ->
        output = format_output(stdin, nil, flags)
        {Command.ok(output), bash}

      [file] ->
        wc_single_file(bash, file, flags)

      multiple ->
        wc_multiple_files(bash, multiple, flags)
    end
  end

  defp wc_single_file(bash, file, flags) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, content} ->
        output = format_output(content, file, flags)
        {Command.ok(output), bash}

      {:error, _} ->
        {Command.error("wc: #{file}: No such file or directory\n"), bash}
    end
  end

  defp wc_multiple_files(bash, files, flags) do
    {outputs, total_counts, err_acc, exit_code} =
      Enum.reduce(files, {[], %{lines: 0, words: 0, bytes: 0}, [], 0}, fn file,
                                                                          {out_acc, totals,
                                                                           err_acc, code} ->
        resolved = InMemoryFs.resolve_path(bash.cwd, file)

        case InMemoryFs.read_file(bash.fs, resolved) do
          {:ok, content} ->
            counts = count_content(content)

            new_totals = %{
              lines: totals.lines + counts.lines,
              words: totals.words + counts.words,
              bytes: totals.bytes + counts.bytes
            }

            line = format_output(content, file, flags)
            {[line | out_acc], new_totals, err_acc, code}

          {:error, _} ->
            err = "wc: #{file}: No such file or directory\n"
            {out_acc, totals, [err | err_acc], 1}
        end
      end)

    total_line = format_counts(total_counts, flags, true) <> " total\n"
    stdout = (Enum.reverse(outputs) ++ [total_line]) |> Enum.join()
    stderr = err_acc |> Enum.reverse() |> Enum.join()

    result = %{stdout: stdout, stderr: stderr, exit_code: exit_code}
    {result, bash}
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

  defp format_counts(counts, %{l: l, w: w, c: c}, _has_file?) do
    # If no flags set, show all. If multiple flags set, show those columns.
    show_all = not l and not w and not c

    parts =
      []
      |> then(fn acc -> if show_all or l, do: [pad_field(counts.lines) | acc], else: acc end)
      |> then(fn acc -> if show_all or w, do: [pad_field(counts.words) | acc], else: acc end)
      |> then(fn acc -> if show_all or c, do: [pad_field(counts.bytes) | acc], else: acc end)
      |> Enum.reverse()

    Enum.join(parts, " ")
  end

  defp format_single_count(n, false), do: Integer.to_string(n)
  defp format_single_count(n, true), do: pad_field(n)

  defp pad_field(n), do: String.pad_leading(Integer.to_string(n), 7)

  defp parse_flags(args), do: parse_flags(args, %{l: false, w: false, c: false}, [])

  defp parse_flags([], flags, files), do: {flags, Enum.reverse(files)}

  defp parse_flags(["--" | rest], flags, files) do
    {flags, Enum.reverse(files) ++ rest}
  end

  defp parse_flags(["-" <> flag_str | rest], flags, files) when flag_str != "" do
    case expand_short_flags(flag_str) do
      {:ok, keys} ->
        new_flags = Enum.reduce(keys, flags, fn key, acc -> %{acc | key => true} end)
        parse_flags(rest, new_flags, files)

      :error ->
        parse_flags(rest, flags, ["-" <> flag_str | files])
    end
  end

  defp parse_flags([arg | rest], flags, files) do
    parse_flags(rest, flags, [arg | files])
  end

  defp expand_short_flags(flag_str) do
    chars = String.to_charlist(flag_str)

    if Enum.all?(chars, &Map.has_key?(@short_flags, &1)) do
      {:ok, Enum.map(chars, &Map.fetch!(@short_flags, &1))}
    else
      :error
    end
  end
end
