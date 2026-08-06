defmodule JustBash.Commands.Grep do
  @moduledoc "The `grep` command - print lines matching a pattern."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FlagParser
  alias JustBash.FS
  alias JustBash.Limit

  @flag_spec %{
    boolean: [
      :i,
      :v,
      :e_ext,
      :f_fixed,
      :p_pcre,
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
      "P" => :p_pcre,
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
      p_pcre: false,
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
    },
    usage: "grep [OPTION]... PATTERNS [FILE]..."
  }

  @usage """
  Usage: grep [OPTION]... PATTERNS [FILE]...
  Try 'grep --help' for more information.
  """

  @impl true
  def names, do: ["grep"]

  @impl true
  def execute(bash, args, stdin) do
    case FlagParser.parse(args, @flag_spec) do
      {:ok, flags, rest} ->
        grep(bash, flags, rest, stdin)

      :help ->
        {Command.ok(FlagParser.help("grep", @flag_spec)), bash}

      {:error, reason} ->
        {Command.error(FlagParser.format_error("grep", reason, @usage), 2), bash}
    end
  end

  defp grep(bash, flags, rest, stdin) do
    case rest do
      [pattern | files] when files != [] ->
        execute_with_files(bash, pattern, files, stdin, flags)

      [pattern] ->
        execute_with_stdin(bash, pattern, stdin, flags)

      _ ->
        {Command.error("grep: missing pattern\n", 2), bash}
    end
  end

  defp execute_with_files(bash, pattern, files, stdin, flags) do
    regex = compile_pattern(bash, pattern, flags)

    # Expand files recursively if -r flag is set
    expanded_files = expand_files(bash, files, flags.r)

    show_filename =
      flags.with_filename or (length(expanded_files) > 1 and not flags.no_filename)

    {results, any_match, errors, fs} =
      Enum.reduce(expanded_files, {[], false, "", bash.fs}, fn file, acc ->
        process_file(bash, file, stdin, regex, flags, show_filename, acc)
      end)

    build_files_result(%{bash | fs: fs}, results, any_match, errors, flags)
  end

  # Expand files recursively when -r flag is set
  defp expand_files(_bash, files, false), do: files

  defp expand_files(bash, files, true) do
    Enum.flat_map(files, fn file ->
      resolved = FS.resolve_path(bash.cwd, file)

      case FS.stat(bash.fs, resolved) do
        {:ok, %VFS.Stat{type: :directory}, _fs} ->
          find_files_recursive(bash.fs, resolved, file, bash.interpreter.deadline)

        {:ok, _, _fs} ->
          [file]

        {:error, _} ->
          [file]
      end
    end)
  end

  # `-r` follows symlinks only when they are named on the command line, so
  # the descent uses `lstat` and skips every link it meets along the way.
  # (`stat` would resolve them, and a link pointing back into the tree being
  # searched would make the recursion re-enter it — twice over, forever.)
  # A whole traversal is one step, so the step counter cannot bound it.
  defp find_files_recursive(fs, full_path, display_path, deadline) do
    Limit.check_deadline!(deadline)

    case FS.readdir(fs, full_path) do
      {:ok, entries, _fs} ->
        Enum.flat_map(entries, fn entry ->
          child_full = join_path(full_path, entry)
          child_display = join_path(display_path, entry)

          case FS.lstat(fs, child_full) do
            {:ok, %VFS.Stat{type: :directory}, _fs} ->
              find_files_recursive(fs, child_full, child_display, deadline)

            {:ok, %VFS.Stat{type: :symlink}, _fs} ->
              []

            {:ok, _, _fs} ->
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

  defp process_file(bash, file, stdin, regex, flags, show_filename, {acc, had_match, errors, fs}) do
    case StdinOperand.read(fs, bash.cwd, file, stdin) do
      {:ok, content, fs} ->
        # GNU names the `-` operand "(standard input)" in the prefix, not "-".
        name = if StdinOperand.stdin?(file), do: "(standard input)", else: file
        prefix = if show_filename, do: "#{name}:", else: ""
        lines = process_content(content, regex, flags, prefix)
        matched = lines != []
        result = format_file_result(name, prefix, lines, matched, flags)
        {if(result, do: [result | acc], else: acc), had_match or matched, errors, fs}

      {:error, error} ->
        {acc, had_match, errors <> "grep: #{file}: #{FS.strerror(error)}\n", fs}
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

  defp build_files_result(bash, results, any_match, errors, flags) do
    exit_code = files_exit_code(any_match, errors != "", flags.q)

    if flags.q do
      {Command.result("", errors, exit_code), bash}
    else
      output = results |> Enum.reverse() |> Enum.join("\n")
      output = if output != "", do: output <> "\n", else: ""
      {Command.result(output, errors, exit_code), bash}
    end
  end

  # "the exit status is 0 if a line is selected, 1 if no lines were selected,
  # and 2 if an error occurred. However, if -q is used and a line is selected,
  # the exit status is 0 even if an error occurred."
  defp files_exit_code(true, _errored, true), do: 0
  defp files_exit_code(_any_match, true, _quiet), do: 2
  defp files_exit_code(true, false, _quiet), do: 0
  defp files_exit_code(false, false, _quiet), do: 1

  defp execute_with_stdin(bash, pattern, stdin, flags) do
    regex = compile_pattern(bash, pattern, flags)
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

  defp compile_pattern(bash, pattern, flags) do
    Limit.check_regex_size!(bash.limits, pattern)
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
