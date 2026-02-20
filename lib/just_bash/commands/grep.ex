defmodule JustBash.Commands.Grep do
  @moduledoc "The `grep` command - print lines matching a pattern."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.Fs.InMemoryFs

  @flag_spec %{
    boolean: [
      :i,
      :v,
      :e_ext,
      :f_fixed,
      :c,
      :l,
      :n,
      :o,
      :q,
      :w,
      :x,
      :r,
      :with_filename,
      :no_filename
    ],
    aliases: %{
      "E" => :e_ext,
      "F" => :f_fixed,
      "H" => :with_filename,
      "h" => :no_filename,
      "R" => :r
    },
    value: [],
    defaults: %{
      i: false,
      v: false,
      e_ext: false,
      f_fixed: false,
      c: false,
      l: false,
      n: false,
      o: false,
      q: false,
      w: false,
      x: false,
      r: false,
      with_filename: false,
      no_filename: false
    }
  }

  @impl true
  def names, do: ["grep"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, rest} = FlagParser.parse(args, @flag_spec)

    case rest do
      [pattern | files] when files != [] ->
        execute_with_files(bash, pattern, files, flags)

      [pattern] ->
        execute_with_stdin(bash, pattern, stdin, flags)

      _ ->
        {Command.error("grep: missing pattern\n", 2), bash}
    end
  end

  defp execute_with_files(bash, pattern, files, flags) do
    regex = compile_pattern(pattern, flags)

    # Expand files recursively if -r flag is set
    expanded_files = expand_files(bash, files, flags.r)

    show_filename =
      flags.with_filename or (length(expanded_files) > 1 and not flags.no_filename)

    {results, any_match} =
      Enum.reduce(expanded_files, {[], false}, fn file, {acc, had_match} ->
        process_file(bash, file, regex, flags, show_filename, acc, had_match)
      end)

    build_files_result(bash, results, any_match, flags)
  end

  # Expand files recursively when -r flag is set
  defp expand_files(_bash, files, false), do: files

  defp expand_files(bash, files, true) do
    Enum.flat_map(files, fn file ->
      resolved = InMemoryFs.resolve_path(bash.cwd, file)

      case InMemoryFs.stat(bash.fs, resolved) do
        {:ok, %{is_directory: true}} ->
          find_files_recursive(bash.fs, resolved, file)

        {:ok, _} ->
          [file]

        {:error, _} ->
          [file]
      end
    end)
  end

  defp find_files_recursive(fs, full_path, display_path) do
    case InMemoryFs.readdir(fs, full_path) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          child_full = join_path(full_path, entry)
          child_display = join_path(display_path, entry)

          case InMemoryFs.stat(fs, child_full) do
            {:ok, %{is_directory: true}} ->
              find_files_recursive(fs, child_full, child_display)

            {:ok, _} ->
              [child_display]

            {:error, _} ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp join_path("/", entry), do: "/#{entry}"
  defp join_path(path, entry), do: "#{path}/#{entry}"

  defp process_file(bash, file, regex, flags, show_filename, acc, had_match) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash, resolved) do
      {:ok, content, _new_bash} ->
        prefix = if show_filename, do: "#{file}:", else: ""
        lines = process_content(content, regex, flags, prefix)
        matched = lines != []
        result = format_file_result(file, prefix, lines, matched, flags)
        {if(result, do: [result | acc], else: acc), had_match or matched}

      {:error, _} ->
        {acc, had_match}
    end
  end

  defp format_file_result(file, prefix, lines, matched, flags) do
    cond do
      flags.q -> nil
      flags.l and matched -> file
      flags.c -> "#{prefix}#{length(lines)}"
      matched -> Enum.join(lines, "\n")
      true -> nil
    end
  end

  defp build_files_result(bash, results, any_match, flags) do
    exit_code = if any_match, do: 0, else: 1

    if flags.q do
      {Command.result("", "", exit_code), bash}
    else
      output = results |> Enum.reverse() |> Enum.join("\n")
      output = if output != "", do: output <> "\n", else: ""
      {Command.result(output, "", exit_code), bash}
    end
  end

  defp execute_with_stdin(bash, pattern, stdin, flags) do
    regex = compile_pattern(pattern, flags)
    lines = process_content(stdin, regex, flags, "")
    matched = lines != []

    build_stdin_result(bash, lines, matched, flags)
  end

  defp build_stdin_result(bash, lines, matched, flags) do
    cond do
      flags.q ->
        {Command.result("", "", if(matched, do: 0, else: 1)), bash}

      flags.c ->
        {Command.ok("#{length(lines)}\n"), bash}

      matched ->
        output = Enum.join(lines, "\n") <> "\n"
        {Command.ok(output), bash}

      true ->
        {Command.result("", "", 1), bash}
    end
  end

  defp compile_pattern(pattern, flags) do
    opts = if flags.i, do: [:caseless], else: []

    regex_pattern =
      cond do
        flags.f_fixed ->
          Regex.escape(pattern)

        flags.w ->
          "\\b" <> pattern <> "\\b"

        flags.x ->
          "^" <> pattern <> "$"

        true ->
          pattern
      end

    case Regex.compile(regex_pattern, opts) do
      {:ok, regex} -> regex
      {:error, _} -> Regex.compile!(Regex.escape(pattern), opts)
    end
  end

  defp grep_line(line, regex, flags, line_num, prefix) do
    matches = Regex.match?(regex, line)
    should_output = if flags.v, do: not matches, else: matches

    if should_output do
      format_matched_line(line, regex, flags, line_num, prefix)
    else
      []
    end
  end

  defp format_matched_line(line, regex, flags, line_num, prefix) do
    cond do
      flags.o ->
        format_only_matches(regex, line, prefix, flags.n, line_num)

      flags.n ->
        [add_prefix(line, prefix, true, line_num)]

      true ->
        [add_prefix(line, prefix, false, line_num)]
    end
  end

  defp format_only_matches(regex, line, prefix, with_line_num, line_num) do
    regex
    |> Regex.scan(line)
    |> List.flatten()
    |> Enum.map(&add_prefix(&1, prefix, with_line_num, line_num))
  end

  defp add_prefix(content, prefix, with_line_num, line_num) do
    line_prefix = if with_line_num, do: "#{line_num}:", else: ""
    prefix <> line_prefix <> content
  end

  defp process_content(content, regex, flags, prefix) do
    lines = String.split(content, "\n", trim: false)

    # Remove trailing empty string if input ended with newline
    lines =
      case List.last(lines) do
        "" -> List.delete_at(lines, -1)
        _ -> lines
      end

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      grep_line(line, regex, flags, line_num, prefix)
    end)
  end
end
