defmodule JustBash.Commands.Sed.Executor do
  @moduledoc """
  Executor for SED commands.

  Processes input content by applying SED commands to each line.
  """

  alias JustBash.Commands.Sed.Parser

  @type line_state :: %{
          pattern_space: String.t(),
          deleted: boolean(),
          printed: boolean(),
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

    # Initialize range state for each command (tracks if we're inside a range)
    # Key is command index, value is whether range is active
    initial_range_state = %{}

    {output, _final_range_state} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({"", initial_range_state}, fn {line, line_num}, {output, range_state} ->
        process_line(line, line_num, total_lines, commands, silent, output, range_state)
      end)

    output
  end

  defp process_line(line, line_num, total_lines, commands, silent, output, range_state) do
    line_state = %{
      pattern_space: line,
      deleted: false,
      printed: false,
      line_num: line_num,
      total_lines: total_lines
    }

    {final_line_state, new_range_state} =
      commands
      |> Enum.with_index()
      |> Enum.reduce({line_state, range_state}, fn {cmd, cmd_idx}, {state, rs} ->
        apply_command(cmd, cmd_idx, state, rs)
      end)

    new_output =
      cond do
        final_line_state.deleted ->
          output

        silent ->
          if final_line_state.printed do
            output <> final_line_state.pattern_space <> "\n"
          else
            output
          end

        true ->
          extra =
            if final_line_state.printed, do: final_line_state.pattern_space <> "\n", else: ""

          output <> final_line_state.pattern_space <> "\n" <> extra
      end

    {new_output, new_range_state}
  end

  defp apply_command(cmd, cmd_idx, state, range_state) do
    if state.deleted do
      {state, range_state}
    else
      {matches, new_range_state} =
        address_matches?(cmd.address1, cmd.address2, state, cmd_idx, range_state)

      if matches do
        {execute_command(cmd.command, state), new_range_state}
      else
        {state, new_range_state}
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
      # We're in the range, check if this line ends it
      if single_address_matches?(addr2, state) do
        # End pattern matched - include this line, then deactivate range
        {true, Map.put(range_state, cmd_idx, false)}
      else
        # Still in range
        {true, range_state}
      end
    else
      # Not in range, check if this line starts it
      if single_address_matches?(addr1, state) do
        # Start pattern matched - activate range
        # Also check if end pattern matches on same line
        if single_address_matches?(addr2, state) do
          # Both start and end match on same line - include but don't stay in range
          {true, range_state}
        else
          # Start matched, end didn't - enter range
          {true, Map.put(range_state, cmd_idx, true)}
        end
      else
        # Not matching start pattern
        {false, range_state}
      end
    end
  end

  defp single_address_matches?({:line, n}, state), do: state.line_num == n
  defp single_address_matches?(:last, state), do: state.line_num == state.total_lines

  defp single_address_matches?({:regex, regex}, state) do
    Regex.match?(regex, state.pattern_space)
  end

  defp execute_command(:noop, state), do: state
  defp execute_command(:delete, state), do: %{state | deleted: true}
  defp execute_command(:print, state), do: %{state | printed: true}

  defp execute_command({:substitute, regex, replacement, flags}, state) do
    global = :global in flags
    print_on_match = :print in flags

    replacement = process_replacement(replacement)

    {new_pattern_space, matched} =
      if global do
        # Global replacement with backref expansion
        # Use Regex.replace with a function to expand backrefs for each match
        {result, had_match} =
          global_replace_with_backrefs(regex, state.pattern_space, replacement)

        {result, had_match}
      else
        case Regex.run(regex, state.pattern_space, return: :index) do
          nil ->
            {state.pattern_space, false}

          [{start, len} | groups] ->
            pre = String.slice(state.pattern_space, 0, start)

            post =
              String.slice(state.pattern_space, start + len, String.length(state.pattern_space))

            group_values =
              Enum.map(groups, fn {s, l} -> String.slice(state.pattern_space, s, l) end)

            replaced =
              expand_backreferences(replacement, state.pattern_space, start, len, group_values)

            {pre <> replaced <> post, true}
        end
      end

    new_state = %{state | pattern_space: new_pattern_space}

    if matched and print_on_match do
      %{new_state | printed: true}
    else
      new_state
    end
  end

  defp global_replace_with_backrefs(regex, string, replacement) do
    # Track if we had any matches
    had_match = Regex.match?(regex, string)

    if had_match do
      # Use Regex.scan to get all matches with capture groups, then manually replace
      result = do_global_replace(regex, string, replacement)
      {result, true}
    else
      {string, false}
    end
  end

  defp do_global_replace(regex, string, replacement) do
    # Get all matches with their positions
    case Regex.scan(regex, string, return: :index) do
      [] ->
        string

      matches ->
        # Process matches from end to start so positions stay valid
        matches
        |> Enum.reverse()
        |> Enum.reduce(string, fn match_indices, acc ->
          [{start, len} | group_indices] = match_indices
          full_match = String.slice(acc, start, len)

          group_values =
            Enum.map(group_indices, fn {s, l} ->
              if s >= 0, do: String.slice(acc, s, l), else: ""
            end)

          # Expand & to full match
          expanded = String.replace(replacement, "&", full_match)
          # Expand numbered backrefs
          expanded = expand_numbered_backrefs(expanded, group_values)

          # Replace in string
          String.slice(acc, 0, start) <>
            expanded <>
            String.slice(acc, start + len, String.length(acc))
        end)
    end
  end

  defp process_replacement(replacement) do
    replacement
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
  end

  defp expand_backreferences(replacement, original, start, len, groups) do
    matched = String.slice(original, start, len)

    replacement
    |> String.replace("&", matched)
    |> expand_numbered_backrefs(groups)
  end

  defp expand_numbered_backrefs(str, groups) do
    Regex.replace(~r/\\(\d)/, str, fn _, num_str ->
      num = String.to_integer(num_str)

      if num > 0 and num <= length(groups) do
        Enum.at(groups, num - 1)
      else
        "\\#{num_str}"
      end
    end)
  end
end
