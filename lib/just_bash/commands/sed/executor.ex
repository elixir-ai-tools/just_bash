defmodule JustBash.Commands.Sed.Executor do
  @moduledoc """
  Executor for SED commands.

  Processes input content by applying SED commands to each line.
  """

  alias JustBash.Commands.Sed.Parser
  alias JustBash.TextRegex

  @type line_state :: %{
          pattern_space: String.t(),
          deleted: boolean(),
          printed: boolean(),
          appended: String.t() | nil,
          inserted: String.t() | nil,
          changed: String.t() | nil,
          line_num: pos_integer(),
          total_lines: pos_integer()
        }

  @doc """
  Process content by applying SED commands.

  Returns the transformed output string.
  """
  @spec execute(String.t(), [Parser.sed_command()], boolean()) :: String.t()
  def execute(content, commands, silent) do
    lines = String.split(content, "\n", trim: false)

    lines =
      if List.last(lines) == "" do
        List.delete_at(lines, -1)
      else
        lines
      end

    total_lines = length(lines)

    # Initialize execution state:
    # - range_state: tracks if we're inside a range (key is command index)
    # - last_regex: tracks the last regex used for empty pattern substitution
    initial_exec_state = %{range_state: %{}, last_regex: nil}

    {output_iodata, _final_exec_state} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], initial_exec_state}, fn {line, line_num}, {output, exec_state} ->
        process_line(line, line_num, total_lines, commands, silent, output, exec_state)
      end)

    IO.iodata_to_binary(output_iodata)
  end

  defp process_line(line, line_num, total_lines, commands, silent, output, exec_state) do
    line_state = %{
      pattern_space: line,
      deleted: false,
      printed: false,
      appended: nil,
      inserted: nil,
      changed: nil,
      line_num: line_num,
      total_lines: total_lines
    }

    {final_line_state, new_exec_state} =
      commands
      |> Enum.with_index()
      |> Enum.reduce({line_state, exec_state}, fn {cmd, cmd_idx}, {state, es} ->
        apply_command(cmd, cmd_idx, state, es)
      end)

    inserted = if final_line_state.inserted, do: [final_line_state.inserted, "\n"], else: []
    appended = if final_line_state.appended, do: [final_line_state.appended, "\n"], else: []

    new_output =
      cond do
        final_line_state.changed != nil ->
          [output, inserted, final_line_state.changed, "\n", appended]

        final_line_state.deleted ->
          [output, inserted, appended]

        silent ->
          if final_line_state.printed do
            [output, inserted, final_line_state.pattern_space, "\n", appended]
          else
            [output, inserted, appended]
          end

        true ->
          extra =
            if final_line_state.printed, do: [final_line_state.pattern_space, "\n"], else: []

          [output, inserted, final_line_state.pattern_space, "\n", appended, extra]
      end

    {new_output, new_exec_state}
  end

  defp apply_command(cmd, cmd_idx, state, exec_state) do
    if state.deleted do
      {state, exec_state}
    else
      {matches, new_range_state} =
        address_matches?(cmd.address1, cmd.address2, state, cmd_idx, exec_state.range_state)

      # Apply negation if present
      negated = Map.get(cmd, :negated, false)
      should_execute = if negated, do: not matches, else: matches

      if should_execute do
        {new_state, new_exec_state} =
          execute_command(cmd.command, state, exec_state)

        {new_state, %{new_exec_state | range_state: new_range_state}}
      else
        {state, %{exec_state | range_state: new_range_state}}
      end
    end
  end

  # No address - always matches
  defp address_matches?(nil, nil, _state, _cmd_idx, range_state), do: {true, range_state}

  # Single address - match on that line only
  defp address_matches?(addr1, nil, state, _cmd_idx, range_state) do
    {single_address_matches?(addr1, state), range_state}
  end

  # Range address - need to track state
  defp address_matches?(addr1, addr2, state, cmd_idx, range_state) do
    in_range = Map.get(range_state, cmd_idx, false)

    if in_range do
      check_range_end(addr2, state, cmd_idx, range_state)
    else
      check_range_start(addr1, addr2, state, cmd_idx, range_state)
    end
  end

  defp check_range_end(addr2, state, cmd_idx, range_state) do
    if single_address_matches?(addr2, state) do
      # End pattern matched - include this line, then deactivate range
      {true, Map.put(range_state, cmd_idx, false)}
    else
      # Still in range
      {true, range_state}
    end
  end

  defp check_range_start(addr1, addr2, state, cmd_idx, range_state) do
    if single_address_matches?(addr1, state) do
      # Start pattern matched - activate range
      # Also check if end pattern matches on same line
      check_same_line_end(addr2, state, cmd_idx, range_state)
    else
      # Not matching start pattern
      {false, range_state}
    end
  end

  defp check_same_line_end(addr2, state, cmd_idx, range_state) do
    if single_address_matches?(addr2, state) do
      # Both start and end match on same line - include but don't stay in range
      {true, range_state}
    else
      # Start matched, end didn't - enter range
      {true, Map.put(range_state, cmd_idx, true)}
    end
  end

  defp single_address_matches?({:line, n}, state), do: state.line_num == n
  defp single_address_matches?(:last, state), do: state.line_num == state.total_lines

  defp single_address_matches?({:regex, regex}, state) do
    TextRegex.match?(regex, state.pattern_space)
  end

  defp execute_command(:noop, state, exec_state), do: {state, exec_state}
  defp execute_command(:delete, state, exec_state), do: {%{state | deleted: true}, exec_state}
  defp execute_command(:print, state, exec_state), do: {%{state | printed: true}, exec_state}

  defp execute_command({:append, text}, state, exec_state),
    do: {%{state | appended: text}, exec_state}

  defp execute_command({:insert, text}, state, exec_state),
    do: {%{state | inserted: text}, exec_state}

  defp execute_command({:change, text}, state, exec_state),
    do: {%{state | changed: text}, exec_state}

  defp execute_command({:translate, source, dest}, state, exec_state) do
    translation = Enum.zip(String.graphemes(source), String.graphemes(dest)) |> Map.new()

    new_pattern_space =
      state.pattern_space
      |> String.graphemes()
      |> Enum.map_join(fn char -> Map.get(translation, char, char) end)

    {%{state | pattern_space: new_pattern_space}, exec_state}
  end

  defp execute_command({:substitute, :last_regex, replacement, flags}, state, exec_state) do
    case exec_state.last_regex do
      nil ->
        # No previous regex - this is an error, but just return unchanged
        {state, exec_state}

      regex ->
        execute_substitute(regex, replacement, flags, state, exec_state)
    end
  end

  defp execute_command({:substitute, regex, replacement, flags}, state, exec_state) do
    # Update last_regex and execute
    new_exec_state = %{exec_state | last_regex: regex}
    execute_substitute(regex, replacement, flags, state, new_exec_state)
  end

  defp execute_substitute(regex, replacement, flags, state, exec_state) do
    global = :global in flags
    print_on_match = :print in flags

    nth =
      Enum.find_value(flags, fn
        {:nth, n} -> n
        _ -> nil
      end)

    replacement = process_replacement(replacement)

    {new_pattern_space, matched} =
      cond do
        global ->
          # Global replacement with backref expansion
          {result, had_match} =
            global_replace_with_backrefs(regex, state.pattern_space, replacement)

          {result, had_match}

        nth != nil ->
          # Replace nth occurrence only
          nth_substitute(regex, state.pattern_space, replacement, nth)

        true ->
          # Replace first occurrence
          single_substitute(regex, state.pattern_space, replacement)
      end

    new_state = %{state | pattern_space: new_pattern_space}

    final_state =
      if matched and print_on_match do
        %{new_state | printed: true}
      else
        new_state
      end

    {final_state, exec_state}
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
