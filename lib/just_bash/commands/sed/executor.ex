defmodule JustBash.Commands.Sed.Executor do
  @moduledoc """
  Executor for SED programs.

  Runs a program the way GNU sed does, one cycle per input line: read the
  line into the pattern space, run the commands in order from the first,
  print the pattern space (unless `-n`), then print the text that `a` and `r`
  queued. `n` and `N` read further lines within a cycle, `D` starts the next
  cycle on what is left of the pattern space without reading, and branches
  move the program counter. A hold space persists across cycles.

  Ranges follow GNU: a numeric end at or before the start line selects only
  the start line, a regex end is first tried on the line after the start,
  `addr,+N` selects N more lines, `addr,~N` runs to the next line number after the
  start that is a multiple of N, and `0,/re/` can end on line 1.
  """

  alias JustBash.Commands.Sed.Parser
  alias JustBash.Limit
  alias JustBash.TextRegex

  @typedoc """
  - `:silent` - `-n`: no automatic print at the end of a cycle
  - `:read_file` - reads the file an `r` command names; `:error` prints nothing
  - `:deadline` - checked on every branch and every `D` restart, which are
    the only ways a program can loop without consuming input
  """
  @type opts :: %{
          optional(:silent) => boolean(),
          optional(:read_file) => (String.t() -> {:ok, String.t()} | :error),
          optional(:deadline) => Limit.Deadline.t() | nil
        }

  @doc """
  Runs `program` over `content` and returns the output.
  """
  @spec execute(String.t(), tuple(), opts() | boolean()) :: String.t()
  def execute(content, program, silent) when is_boolean(silent),
    do: execute(content, program, %{silent: silent})

  def execute(content, program, opts) do
    lines = String.split(content, "\n", trim: false)
    lines = if List.last(lines) == "", do: List.delete_at(lines, -1), else: lines

    state = %{
      program: program,
      size: tuple_size(program),
      silent: Map.get(opts, :silent, false),
      read_file: Map.get(opts, :read_file, fn _ -> :error end),
      deadline: Map.get(opts, :deadline),
      input: lines,
      line_num: 0,
      pattern: "",
      hold: "",
      substituted: false,
      ranges: %{},
      last_regex: nil,
      queue: [],
      out: []
    }

    state |> cycle() |> Map.fetch!(:out) |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # --- Cycles -------------------------------------------------------------

  defp cycle(%{input: []} = state), do: state

  defp cycle(state) do
    state |> read_line() |> run(0)
  end

  # Reads the next input line into the pattern space. Text queued by `a` and
  # `r` is printed first, as GNU prints it whenever a new line is read.
  defp read_line(%{input: [line | rest]} = state) do
    %{
      flush_queue(state)
      | input: rest,
        line_num: state.line_num + 1,
        pattern: line,
        substituted: false
    }
  end

  defp run(state, pc) when pc >= state.size, do: finish(state, true)

  defp run(state, pc) do
    cmd = elem(state.program, pc)
    {matched, state} = matches?(cmd, pc, state)

    if matched do
      case execute_command(cmd.command, cmd, pc, state) do
        {:next, state} -> run(state, pc + 1)
        {:jump, state, target} -> jump(state, pc, target)
        {:end_cycle, state, autoprint} -> finish(state, autoprint)
        {:restart, state} -> restart(state)
        {:quit, state, autoprint} -> quit(state, autoprint)
      end
    else
      case cmd.command do
        {:block, close} -> run(state, close + 1)
        _ -> run(state, pc + 1)
      end
    end
  end

  # A backward jump is the one way a program loops within a line, so each one
  # checks the wall clock (`:a;s/x/xx/;ta` never ends).
  defp jump(state, _pc, :end), do: finish(state, true)

  defp jump(state, pc, target) do
    if target <= pc, do: Limit.check_deadline!(state.deadline)
    run(state, target)
  end

  defp finish(state, autoprint) do
    state
    |> autoprint(autoprint)
    |> flush_queue()
    |> cycle()
  end

  # `D` with a newline in the pattern space: the next cycle runs on what is
  # left of it, without reading a line and without printing it first.
  defp restart(state) do
    Limit.check_deadline!(state.deadline)
    state |> flush_queue() |> run(0)
  end

  defp quit(state, autoprint) do
    state |> autoprint(autoprint) |> flush_queue()
  end

  defp autoprint(%{silent: false} = state, true), do: emit(state, [state.pattern, "\n"])
  defp autoprint(state, _autoprint), do: state

  defp emit(state, iodata), do: %{state | out: [iodata | state.out]}

  defp flush_queue(%{queue: []} = state), do: state

  defp flush_queue(state) do
    state.queue
    |> Enum.reverse()
    |> Enum.reduce(%{state | queue: []}, fn
      {:text, text}, state ->
        emit(state, [text, "\n"])

      {:file, path}, state ->
        case state.read_file.(path) do
          {:ok, content} -> emit(state, content)
          :error -> state
        end
    end)
  end

  defp queue(state, item), do: %{state | queue: [item | state.queue]}

  # --- Addresses ----------------------------------------------------------

  defp matches?(%{address1: nil} = cmd, _pc, state), do: {not cmd.negated, state}

  defp matches?(%{address2: nil} = cmd, _pc, state) do
    {matched, state} = address?(cmd.address1, state)
    {matched != cmd.negated, state}
  end

  defp matches?(cmd, pc, state) do
    {matched, state} = in_range?(cmd, pc, state)
    {matched != cmd.negated, state}
  end

  defp in_range?(cmd, pc, state) do
    case Map.get(state.ranges, pc) do
      {:active, ending} -> continue_range(ending, pc, state)
      _ -> start_range(cmd, pc, state)
    end
  end

  # `0,/re/` is active before line 1, so its regex is tried on line 1 too.
  defp start_range(%{address1: {:line, 0}, address2: ending}, pc, state) do
    if Map.has_key?(state.ranges, pc) do
      {false, state}
    else
      continue_range(ending, pc, state)
    end
  end

  defp start_range(%{address1: start, address2: ending}, pc, state) do
    case address?(start, state) do
      {false, state} -> {false, state}
      {true, state} -> {true, open_range(ending, pc, state)}
    end
  end

  defp open_range(ending, pc, state) do
    line = state.line_num

    case ending do
      {:line, last} -> numeric_range(last, pc, state)
      {:plus, n} -> numeric_range(line + n, pc, state)
      {:multiple, 0} -> numeric_range(line, pc, state)
      {:multiple, n} -> numeric_range(next_multiple(line, n), pc, state)
      _address -> set_range(state, pc, {:active, ending})
    end
  end

  defp numeric_range(last, pc, state) do
    if last <= state.line_num,
      do: set_range(state, pc, :closed),
      else: set_range(state, pc, {:active, {:until, last}})
  end

  # The first multiple of `n` after `line`: GNU runs `4,~4` to line 8, not
  # just line 4.
  defp next_multiple(line, n), do: (div(line, n) + 1) * n

  # A numeric end closes the range when the line number reaches it, and a
  # line past it (skipped by `N`) is outside the range.
  defp continue_range({:until, last}, pc, state) do
    line = state.line_num
    state = if line >= last, do: set_range(state, pc, :closed), else: state
    {line <= last, state}
  end

  defp continue_range(ending, pc, state) do
    case address?(ending, state) do
      {true, state} -> {true, set_range(state, pc, :closed)}
      {false, state} -> {true, set_range(state, pc, {:active, ending})}
    end
  end

  defp set_range(state, pc, value), do: %{state | ranges: Map.put(state.ranges, pc, value)}

  defp address?({:line, n}, state), do: {state.line_num == n, state}
  defp address?(:last, state), do: {state.input == [], state}

  defp address?({:step, first, 0}, state), do: {state.line_num == first, state}

  defp address?({:step, first, step}, state) do
    line = state.line_num
    {line >= first and rem(line - first, step) == 0, state}
  end

  defp address?({:regex, :last}, %{last_regex: nil} = state), do: {false, state}
  defp address?({:regex, :last}, state), do: address?({:regex, state.last_regex}, state)

  defp address?({:regex, regex}, state),
    do: {TextRegex.match?(regex, state.pattern), %{state | last_regex: regex}}

  # --- Commands -----------------------------------------------------------

  defp execute_command(:noop, _cmd, _pc, state), do: {:next, state}
  defp execute_command({:label, _}, _cmd, _pc, state), do: {:next, state}
  defp execute_command({:block, _close}, _cmd, _pc, state), do: {:next, state}
  defp execute_command(:block_end, _cmd, _pc, state), do: {:next, state}

  defp execute_command(:delete, _cmd, _pc, state), do: {:end_cycle, state, false}

  defp execute_command(:delete_first_line, _cmd, _pc, state) do
    case String.split(state.pattern, "\n", parts: 2) do
      [_first, rest] -> {:restart, %{state | pattern: rest}}
      [_only] -> {:end_cycle, state, false}
    end
  end

  defp execute_command(:print, _cmd, _pc, state),
    do: {:next, emit(state, [state.pattern, "\n"])}

  defp execute_command(:print_first_line, _cmd, _pc, state) do
    [first | _] = String.split(state.pattern, "\n", parts: 2)
    {:next, emit(state, [first, "\n"])}
  end

  # With no next line, GNU prints the pattern space and stops, so `$!N` and
  # `N` give the same output on the last line.
  defp execute_command(:append_next, _cmd, _pc, %{input: []} = state),
    do: {:quit, state, true}

  defp execute_command(:append_next, _cmd, _pc, state) do
    pattern = state.pattern
    state = read_line(state)
    {:next, %{state | pattern: pattern <> "\n" <> state.pattern}}
  end

  defp execute_command(:next, _cmd, _pc, %{input: []} = state), do: {:quit, state, true}

  defp execute_command(:next, _cmd, _pc, state),
    do: {:next, state |> autoprint(true) |> read_line()}

  defp execute_command(:hold, _cmd, _pc, state), do: {:next, %{state | hold: state.pattern}}

  defp execute_command(:hold_append, _cmd, _pc, state),
    do: {:next, %{state | hold: state.hold <> "\n" <> state.pattern}}

  defp execute_command(:get, _cmd, _pc, state), do: {:next, %{state | pattern: state.hold}}

  defp execute_command(:get_append, _cmd, _pc, state),
    do: {:next, %{state | pattern: state.pattern <> "\n" <> state.hold}}

  defp execute_command(:exchange, _cmd, _pc, state),
    do: {:next, %{state | pattern: state.hold, hold: state.pattern}}

  defp execute_command(:zap, _cmd, _pc, state), do: {:next, %{state | pattern: ""}}

  defp execute_command(:line_number, _cmd, _pc, state),
    do: {:next, emit(state, [Integer.to_string(state.line_num), "\n"])}

  defp execute_command(:quit, _cmd, _pc, state), do: {:quit, state, true}
  defp execute_command(:quit_silently, _cmd, _pc, state), do: {:quit, %{state | queue: []}, false}

  defp execute_command({:append, text}, _cmd, _pc, state),
    do: {:next, queue(state, {:text, text})}

  defp execute_command({:read_file, path}, _cmd, _pc, state),
    do: {:next, queue(state, {:file, path})}

  defp execute_command({:insert, text}, _cmd, _pc, state),
    do: {:next, emit(state, [text, "\n"])}

  # `c` over a range prints its text once, at the end of the range; on a
  # single line, or negated, it prints it for every line it replaces.
  defp execute_command({:change, text}, cmd, pc, state) do
    print? =
      cmd.address2 == nil or cmd.negated or not match?({:active, _}, Map.get(state.ranges, pc))

    state = if print?, do: emit(state, [text, "\n"]), else: state
    {:end_cycle, state, false}
  end

  defp execute_command({:branch, target}, _cmd, _pc, state), do: {:jump, state, target}

  defp execute_command({:branch_if_substituted, target}, _cmd, _pc, state) do
    if state.substituted,
      do: {:jump, %{state | substituted: false}, target},
      else: {:next, state}
  end

  defp execute_command({:branch_unless_substituted, target}, _cmd, _pc, state) do
    if state.substituted,
      do: {:next, %{state | substituted: false}},
      else: {:jump, state, target}
  end

  defp execute_command({:translate, source, dest}, _cmd, _pc, state) do
    translation = Enum.zip(String.graphemes(source), String.graphemes(dest)) |> Map.new()

    pattern =
      state.pattern
      |> String.graphemes()
      |> Enum.map_join(fn char -> Map.get(translation, char, char) end)

    {:next, %{state | pattern: pattern}}
  end

  defp execute_command({:substitute, :last_regex, replacement, flags}, _cmd, _pc, state) do
    case state.last_regex do
      # No previous regex: GNU reports an error; this leaves the line unchanged.
      nil -> {:next, state}
      regex -> {:next, substitute(regex, replacement, flags, state)}
    end
  end

  defp execute_command({:substitute, regex, replacement, flags}, _cmd, _pc, state),
    do: {:next, substitute(regex, replacement, flags, %{state | last_regex: regex})}

  # --- Substitution -------------------------------------------------------

  @spec substitute(Regex.t(), String.t(), Parser.substitute_flags(), map()) :: map()
  defp substitute(regex, replacement, flags, state) do
    nth =
      Enum.find_value(flags, fn
        {:nth, n} -> n
        _ -> nil
      end)

    replacement = process_replacement(replacement)

    {pattern, matched} =
      cond do
        :global in flags -> global_replace_with_backrefs(regex, state.pattern, replacement)
        nth != nil -> nth_substitute(regex, state.pattern, replacement, nth)
        true -> single_substitute(regex, state.pattern, replacement)
      end

    state = %{state | pattern: pattern, substituted: state.substituted or matched}

    if matched and :print in flags, do: emit(state, [pattern, "\n"]), else: state
  end

  defp single_substitute(regex, pattern_space, replacement) do
    case TextRegex.run(regex, pattern_space, return: :index) do
      nil ->
        {pattern_space, false}

      [{start, len} | group_indices] ->
        group_values = extract_group_values(group_indices, pattern_space)
        full_match = :binary.part(pattern_space, start, len)
        expanded = expand_replacement(replacement, full_match, group_values)

        result =
          [
            :binary.part(pattern_space, 0, start),
            expanded | tail_part(pattern_space, start + len)
          ]
          |> IO.iodata_to_binary()

        {result, true}
    end
  end

  defp nth_substitute(regex, pattern_space, replacement, nth) do
    case TextRegex.scan(regex, pattern_space, return: :index) do
      [] ->
        {pattern_space, false}

      matches when length(matches) < nth ->
        {pattern_space, false}

      matches ->
        [{start, len} | group_indices] = Enum.at(matches, nth - 1)
        group_values = extract_group_values(group_indices, pattern_space)
        full_match = :binary.part(pattern_space, start, len)
        expanded = expand_replacement(replacement, full_match, group_values)

        result =
          [
            :binary.part(pattern_space, 0, start),
            expanded | tail_part(pattern_space, start + len)
          ]
          |> IO.iodata_to_binary()

        {result, true}
    end
  end

  defp global_replace_with_backrefs(regex, string, replacement) do
    case TextRegex.scan(regex, string, return: :index) do
      [] ->
        {string, false}

      matches ->
        # A replacement of plain text is the same for every match.
        literal_only? = Enum.all?(replacement, &is_binary/1)

        result =
          build_global_replacement(matches, string, replacement, 0, literal_only?)
          |> IO.iodata_to_binary()

        {result, true}
    end
  end

  # Walk matches left-to-right, building iodata: [gap, replacement, gap, replacement, ... tail]
  defp build_global_replacement([], string, _replacement, pos, _literal_only?) do
    [tail_part(string, pos)]
  end

  defp build_global_replacement([match | rest], string, replacement, pos, literal_only?) do
    [{start, len} | group_indices] = match
    gap = :binary.part(string, pos, start - pos)

    expanded =
      if literal_only? do
        replacement
      else
        full_match = :binary.part(string, start, len)
        group_values = extract_group_values(group_indices, string)
        expand_replacement(replacement, full_match, group_values)
      end

    [
      gap,
      expanded
      | build_global_replacement(rest, string, replacement, start + len, literal_only?)
    ]
  end

  # Returns the tail of a binary from byte offset `pos` to end.
  defp tail_part(string, pos) do
    [:binary.part(string, pos, byte_size(string) - pos)]
  end

  defp extract_group_values(group_indices, string) do
    Enum.map(group_indices, fn {s, l} ->
      if s >= 0, do: :binary.part(string, s, l), else: ""
    end)
  end

  # Reads the replacement once, left to right, into literal text, `:match` for
  # `&` and `{:group, n}` for `\1`-`\9`, as GNU sed does. `\n` and `\t` are a
  # newline and a tab; a backslash before any other character makes that
  # character literal, so `\&` is an ampersand, `\/` a slash and `\\` one
  # backslash. Expanding per match then never re-reads text it inserted: a
  # matched line containing `\1` or `&` is copied as is.
  defp process_replacement(replacement) do
    replacement
    |> tokenize_replacement([], "")
    |> Enum.reverse()
  end

  defp tokenize_replacement("", tokens, literal), do: push_literal(tokens, literal)

  defp tokenize_replacement("&" <> rest, tokens, literal),
    do: tokenize_replacement(rest, [:match | push_literal(tokens, literal)], "")

  defp tokenize_replacement(<<"\\", d, rest::binary>>, tokens, literal) when d in ?0..?9,
    do: tokenize_replacement(rest, [{:group, d - ?0} | push_literal(tokens, literal)], "")

  defp tokenize_replacement("\\n" <> rest, tokens, literal),
    do: tokenize_replacement(rest, tokens, literal <> "\n")

  defp tokenize_replacement("\\t" <> rest, tokens, literal),
    do: tokenize_replacement(rest, tokens, literal <> "\t")

  defp tokenize_replacement("\\" <> rest, tokens, literal) do
    case String.next_grapheme(rest) do
      {char, rest} -> tokenize_replacement(rest, tokens, literal <> char)
      nil -> push_literal(tokens, literal <> "\\")
    end
  end

  defp tokenize_replacement(<<c, rest::binary>>, tokens, literal),
    do: tokenize_replacement(rest, tokens, literal <> <<c>>)

  defp push_literal(tokens, ""), do: tokens
  defp push_literal(tokens, literal), do: [literal | tokens]

  # The text one match is replaced with. `\0` is the whole match, as in GNU
  # sed; a group the regex does not have is empty.
  defp expand_replacement(tokens, full_match, groups) do
    Enum.map(tokens, fn
      :match -> full_match
      {:group, 0} -> full_match
      {:group, n} -> Enum.at(groups, n - 1, "")
      literal -> literal
    end)
  end
end
