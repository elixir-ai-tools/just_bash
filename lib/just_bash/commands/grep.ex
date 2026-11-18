defmodule JustBash.Commands.Grep do
  @moduledoc "The `grep` command - print lines matching a pattern."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FlagParser
  alias JustBash.FS
  alias JustBash.Limit
  alias JustBash.TextRegex

  @context_label "context length argument"

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
      "R" => :r,
      "A" => :after_context,
      "B" => :before_context,
      "C" => :both_context,
      "-after-context" => :after_context,
      "-before-context" => :before_context,
      "-context" => :both_context
    },
    value: [:after_context, :before_context, :both_context],
    integer: [:after_context, :before_context, :both_context],
    value_labels: %{
      after_context: @context_label,
      before_context: @context_label,
      both_context: @context_label
    },
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
      no_filename: false,
      after_context: nil,
      before_context: nil,
      both_context: nil
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
    case FlagParser.parse(split_long_values(args), @flag_spec) do
      {:ok, flags, rest} ->
        grep(bash, context(flags), rest, stdin)

      :help ->
        {Command.ok(FlagParser.help("grep", @flag_spec)), bash}

      # GNU names the bad count first: `grep: x: invalid context length argument`.
      {:error, {:invalid_value, @context_label, value}} ->
        {Command.error("grep: #{value}: invalid #{@context_label}\n", 2), bash}

      {:error, reason} ->
        {Command.error(FlagParser.format_error("grep", reason, @usage), 2), bash}
    end
  end

  # `--context=2` is `--context 2`. Only the context options take a value, so
  # only they are split; anything after `--` is an operand and left alone.
  defp split_long_values(args) do
    {options, operands} = Enum.split_while(args, &(&1 != "--"))

    Enum.flat_map(options, fn
      "--" <> _ = arg ->
        case String.split(arg, "=", parts: 2) do
          [name, value] when name in ["--after-context", "--before-context", "--context"] ->
            [name, value]

          _ ->
            [arg]
        end

      arg ->
        [arg]
    end) ++ operands
  end

  # The lines to print around each selected line, as `{before, after}`, or nil
  # without a context option. `-A` and `-B` win over `-C` in either order, as
  # in GNU, where `-C` only fills in the sides not given.
  defp context(%{after_context: nil, before_context: nil, both_context: nil} = flags),
    do: Map.put(flags, :context, nil)

  defp context(flags) do
    Map.put(
      flags,
      :context,
      {flags.before_context || flags.both_context || 0,
       flags.after_context || flags.both_context || 0}
    )
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

    # `-q` is specified to exit "immediately ... if any match is found", so real
    # grep never opens the operands after the first matching one and never
    # reports their errors. Halting is that short-circuit — and it keeps the
    # error of an operand read *before* the match, which GNU also prints.
    {results, any_match, errors, fs} =
      Enum.reduce_while(expanded_files, {[], false, "", bash.fs}, fn file, acc ->
        case process_file(bash, file, stdin, regex, flags, show_filename, acc) do
          {_, true, _, _} = matched when flags.q -> {:halt, matched}
          next -> {:cont, next}
        end
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
        label = if show_filename, do: name
        {selected, lines} = process_content(content, regex, flags, label)
        matched = selected > 0
        result = format_file_result(name, label, selected, lines, matched, flags)
        {if(result, do: [result | acc], else: acc), had_match or matched, errors, fs}

      {:error, error} ->
        {acc, had_match, errors <> "grep: #{file}: #{FS.strerror(error)}\n", fs}
    end
  end

  defp format_file_result(file, label, selected, lines, matched, flags) do
    cond do
      flags.q -> nil
      flags.l and matched -> file
      flags.c -> add_prefix(Integer.to_string(selected), label, ":", nil)
      matched -> Enum.join(lines, "\n")
      true -> nil
    end
  end

  defp build_files_result(bash, results, any_match, errors, flags) do
    exit_code = files_exit_code(any_match, errors != "", flags.q)

    if flags.q do
      {Command.result("", errors, exit_code), bash}
    else
      # With context, GNU separates one file's lines from the next file's
      # with `--`, as it does groups within a file.
      joiner = if flags.context && not flags.c && not flags.l, do: "\n--\n", else: "\n"
      output = results |> Enum.reverse() |> Enum.join(joiner)
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
    {selected, lines} = process_content(stdin, regex, flags, nil)
    matched = selected > 0

    build_stdin_result(bash, selected, lines, matched, flags)
  end

  defp build_stdin_result(bash, selected, lines, matched, flags) do
    cond do
      flags.q ->
        {Command.result("", "", if(matched, do: 0, else: 1)), bash}

      flags.c ->
        {Command.ok("#{selected}\n"), bash}

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

    base_pattern =
      if flags.f_fixed do
        Regex.escape(pattern)
      else
        bre_pipes_to_pcre(pattern, flags)
      end

    # The group is not cosmetic: `\bfoo|bar\b` is read as `(\bfoo)|(bar\b)`,
    # so each anchor would bind to a single branch and `-w`/`-x` would admit
    # unanchored matches of every other one.
    regex_pattern =
      cond do
        flags.w -> "\\b(?:" <> base_pattern <> ")\\b"
        flags.x -> "^(?:" <> base_pattern <> ")$"
        true -> base_pattern
      end

    case TextRegex.compile(regex_pattern, opts) do
      {:ok, regex} -> regex
      {:error, _} -> TextRegex.compile!(Regex.escape(pattern), opts)
    end
  end

  # Real `grep` without `-E`/`-P` is BRE, where `\|` is alternation and a bare
  # `|` is an ordinary character. This is PCRE (`Regex.compile/2`), where those
  # two meanings are exactly swapped — and both spellings compile cleanly either
  # way, so a BRE pattern passed through unchanged never reaches the
  # `{:error, _}` fallback above. It just quietly matches something else: `a\|b`
  # looks for a literal pipe the input almost never contains, turning the single
  # most common agent idiom (`grep -r "a\|b"`) into a false negative, while
  # `a|b` matches either half of a pattern whose author meant it verbatim.
  #
  # One left-to-right scan fixes both, and scanning is what makes the escaped
  # forms come out right. `a\\|b` is a literal backslash followed by a BRE pipe;
  # a blind `String.replace(pattern, "\\|", "|")` finds a `\|` straddling the
  # backslash pair and rewrites it, so the pattern ends up matching the literal
  # text `a|b`. Consuming each backslash together with the character it escapes
  # means an escaped character is never re-read as syntax.
  #
  # Only the pipe is translated. Full BRE emulation — bare `(`, `)`, `{` as
  # literals, `\(...\)` as groups, `\{n,m\}` as bounds — is a much larger
  # surface with more ways to land partially right, and is left alone rather
  # than half-translated.
  defp bre_pipes_to_pcre(pattern, flags) do
    if flags.e_ext or flags.p_pcre do
      pattern
    else
      pattern |> do_bre_pipes_to_pcre([]) |> IO.iodata_to_binary()
    end
  end

  defp do_bre_pipes_to_pcre(<<>>, acc), do: Enum.reverse(acc)

  defp do_bre_pipes_to_pcre(<<"\\|", rest::binary>>, acc),
    do: do_bre_pipes_to_pcre(rest, ["|" | acc])

  defp do_bre_pipes_to_pcre(<<"\\", escaped::binary-size(1), rest::binary>>, acc),
    do: do_bre_pipes_to_pcre(rest, ["\\" <> escaped | acc])

  defp do_bre_pipes_to_pcre(<<"|", rest::binary>>, acc),
    do: do_bre_pipes_to_pcre(rest, ["\\|" | acc])

  defp do_bre_pipes_to_pcre(<<char::binary-size(1), rest::binary>>, acc),
    do: do_bre_pipes_to_pcre(rest, [char | acc])

  defp selected?(line, regex, flags) do
    TextRegex.match?(regex, line) != flags.v
  end

  # A selected line is printed with `:` after its file name and line number;
  # a context line with `-`.
  defp format_selected_line(line, regex, flags, line_num, label) do
    number = if flags.n, do: line_num

    if flags.o do
      regex
      |> TextRegex.scan(line)
      |> List.flatten()
      |> Enum.map(&add_prefix(&1, label, ":", number))
    else
      [add_prefix(line, label, ":", number)]
    end
  end

  defp add_prefix(content, label, separator, line_num) do
    file_part = if label, do: label <> separator, else: ""
    line_part = if line_num, do: "#{line_num}#{separator}", else: ""
    file_part <> line_part <> content
  end

  # The number of selected lines, and the lines to print.
  defp process_content(content, regex, flags, label) do
    lines = String.split(content, "\n", trim: false)

    # Remove trailing empty string if input ended with newline
    lines =
      case List.last(lines) do
        "" -> List.delete_at(lines, -1)
        _ -> lines
      end

    indexed = Enum.with_index(lines, 1)

    selected =
      for {line, num} <- indexed, selected?(line, regex, flags), into: MapSet.new(), do: num

    output =
      case flags.context do
        nil ->
          Enum.flat_map(indexed, fn {line, num} ->
            if num in selected, do: format_selected_line(line, regex, flags, num, label), else: []
          end)

        {before, after_count} ->
          with_context(indexed, selected, before, after_count, regex, flags, label)
      end

    {MapSet.size(selected), output}
  end

  # Each selected line with up to `before` lines above it and `after_count`
  # below. Overlapping or touching groups run together; a gap between two
  # groups is marked by a `--` line. Under `-o` the context lines are not
  # printed, but the groups, and so the separators, are the same.
  defp with_context(indexed, selected, before, after_count, regex, flags, label) do
    last = length(indexed)

    shown =
      selected
      |> Enum.flat_map(&Enum.to_list(max(&1 - before, 1)..min(&1 + after_count, last)//1))
      |> MapSet.new()

    {output, _previous} =
      Enum.reduce(indexed, {[], nil}, fn {line, num}, {acc, previous} ->
        if num in shown do
          separator = if previous && num > previous + 1, do: ["--"], else: []
          printed = shown_line(line, num, selected, regex, flags, label)
          {Enum.reverse(printed) ++ Enum.reverse(separator) ++ acc, num}
        else
          {acc, previous}
        end
      end)

    Enum.reverse(output)
  end

  defp shown_line(line, num, selected, regex, flags, label) do
    cond do
      num in selected -> format_selected_line(line, regex, flags, num, label)
      flags.o -> []
      true -> [add_prefix(line, label, "-", if(flags.n, do: num))]
    end
  end
end
