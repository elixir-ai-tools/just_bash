defmodule JustBash.Parser.WordParts do
  @moduledoc """
  Word Parts Parser

  Parses word token values into AST nodes for:
  - Variable expansion: $VAR, ${VAR}, ${VAR:-default}
  - Command substitution: $(cmd), `cmd`
  - Arithmetic expansion: $((expr))
  - Glob patterns: *, ?, [...]
  - Quoted strings: 'literal', "with $expansion"
  - Tilde expansion: ~, ~user
  """

  alias JustBash.AST

  @type parse_result :: [AST.word_part()]

  @doc """
  Parse a word value into its component parts.

  ## Options
  - `:quoted` - true if the token was double-quoted
  - `:single_quoted` - true if the token was single-quoted
  - `:assignment` - true if this is the RHS of an assignment
  """
  @spec parse(String.t(), keyword()) :: parse_result()
  def parse(value, opts \\ []) do
    quoted = Keyword.get(opts, :quoted, false)
    single_quoted = Keyword.get(opts, :single_quoted, false)
    is_assignment = Keyword.get(opts, :assignment, false)

    cond do
      single_quoted ->
        [AST.single_quoted(value)]

      quoted ->
        inner_parts = parse_double_quoted_content(value)
        [AST.double_quoted(inner_parts)]

      true ->
        parse_unquoted(value, is_assignment)
    end
  end

  defp parse_unquoted(value, is_assignment) do
    parse_unquoted_loop(value, 0, "", [], is_assignment)
  end

  defp parse_unquoted_loop(value, i, literal, parts, _is_assignment) when i >= byte_size(value) do
    flush_literal(literal, parts)
  end

  defp parse_unquoted_loop(value, i, literal, parts, is_assignment) do
    char = String.at(value, i)

    cond do
      char == "\\" and i + 1 < String.length(value) ->
        next = String.at(value, i + 1)

        if next in ["$", "`", "\\", "\"", "\n"] do
          parse_unquoted_loop(value, i + 2, literal <> next, parts, is_assignment)
        else
          parse_unquoted_loop(value, i + 2, literal <> "\\" <> next, parts, is_assignment)
        end

      char == "'" ->
        parts = flush_literal(literal, parts)
        {quoted_content, end_idx} = parse_single_quoted(value, i + 1)
        new_parts = parts ++ [AST.single_quoted(quoted_content)]
        parse_unquoted_loop(value, end_idx, "", new_parts, is_assignment)

      char == "\"" ->
        parts = flush_literal(literal, parts)
        {inner_parts, end_idx} = parse_double_quoted(value, i + 1)
        new_parts = parts ++ [AST.double_quoted(inner_parts)]
        parse_unquoted_loop(value, end_idx, "", new_parts, is_assignment)

      char == "$" and String.at(value, i + 1) == "'" ->
        parts = flush_literal(literal, parts)
        {ansi_content, end_idx} = parse_ansi_c_quoted(value, i + 2)
        new_parts = parts ++ [AST.literal(ansi_content)]
        parse_unquoted_loop(value, end_idx, "", new_parts, is_assignment)

      char == "$" ->
        parts = flush_literal(literal, parts)
        {part, end_idx} = parse_expansion(value, i)
        new_parts = if part, do: parts ++ [part], else: parts
        parse_unquoted_loop(value, end_idx, "", new_parts, is_assignment)

      char == "`" ->
        parts = flush_literal(literal, parts)
        {part, end_idx} = parse_backtick_substitution(value, i)
        new_parts = parts ++ [part]
        parse_unquoted_loop(value, end_idx, "", new_parts, is_assignment)

      char == "~" and (i == 0 or String.at(value, i - 1) in ["=", ":"]) ->
        tilde_end = find_tilde_end(value, i)
        after_tilde = String.at(value, tilde_end)

        if after_tilde in [nil, "/", ":"] do
          parts = flush_literal(literal, parts)

          user =
            if tilde_end > i + 1, do: String.slice(value, (i + 1)..(tilde_end - 1)), else: nil

          new_parts = parts ++ [%AST.TildeExpansion{user: user}]
          parse_unquoted_loop(value, tilde_end, "", new_parts, is_assignment)
        else
          parse_unquoted_loop(value, i + 1, literal <> char, parts, is_assignment)
        end

      char in ["*", "?"] ->
        parts = flush_literal(literal, parts)
        new_parts = parts ++ [%AST.Glob{pattern: char}]
        parse_unquoted_loop(value, i + 1, "", new_parts, is_assignment)

      char == "[" ->
        case find_glob_bracket_end(value, i) do
          {:ok, end_idx} ->
            parts = flush_literal(literal, parts)
            pattern = String.slice(value, i..end_idx)
            new_parts = parts ++ [%AST.Glob{pattern: pattern}]
            parse_unquoted_loop(value, end_idx + 1, "", new_parts, is_assignment)

          :error ->
            parse_unquoted_loop(value, i + 1, literal <> char, parts, is_assignment)
        end

      true ->
        parse_unquoted_loop(value, i + 1, literal <> char, parts, is_assignment)
    end
  end

  defp flush_literal("", parts), do: parts
  defp flush_literal(literal, parts), do: parts ++ [AST.literal(literal)]

  defp parse_single_quoted(value, start) do
    case :binary.match(value, "'", scope: {start, byte_size(value) - start}) do
      {pos, _} ->
        content = String.slice(value, start..(pos - 1)//1)
        {content, pos + 1}

      :nomatch ->
        content = String.slice(value, start..-1//1)
        {content, String.length(value)}
    end
  end

  defp parse_double_quoted(value, start) do
    parse_double_quoted_loop(value, start, "", [])
  end

  defp parse_double_quoted_loop(value, i, literal, parts) when i >= byte_size(value) do
    {flush_literal(literal, parts), i}
  end

  defp parse_double_quoted_loop(value, i, literal, parts) do
    char = String.at(value, i)

    cond do
      char == "\"" ->
        {flush_literal(literal, parts), i + 1}

      char == "\\" and i + 1 < String.length(value) ->
        next = String.at(value, i + 1)

        if next in ["\"", "\\", "$", "`", "\n"] do
          parse_double_quoted_loop(value, i + 2, literal <> next, parts)
        else
          parse_double_quoted_loop(value, i + 1, literal <> char, parts)
        end

      char == "$" ->
        parts = flush_literal(literal, parts)
        {part, end_idx} = parse_expansion(value, i)
        new_parts = if part, do: parts ++ [part], else: parts
        parse_double_quoted_loop(value, end_idx, "", new_parts)

      char == "`" ->
        parts = flush_literal(literal, parts)
        {part, end_idx} = parse_backtick_substitution(value, i)
        new_parts = parts ++ [part]
        parse_double_quoted_loop(value, end_idx, "", new_parts)

      true ->
        parse_double_quoted_loop(value, i + 1, literal <> char, parts)
    end
  end

  defp parse_double_quoted_content(value) do
    parse_dq_content_loop(value, 0, "", [])
  end

  defp parse_dq_content_loop(value, i, literal, parts) when i >= byte_size(value) do
    flush_literal(literal, parts)
  end

  defp parse_dq_content_loop(value, i, literal, parts) do
    char = String.at(value, i)

    cond do
      char == "\\" and i + 1 < String.length(value) ->
        next = String.at(value, i + 1)

        if next in ["$", "`"] do
          parse_dq_content_loop(value, i + 2, literal <> next, parts)
        else
          parse_dq_content_loop(value, i + 1, literal <> char, parts)
        end

      char == "$" ->
        parts = flush_literal(literal, parts)
        {part, end_idx} = parse_expansion(value, i)
        new_parts = if part, do: parts ++ [part], else: parts
        parse_dq_content_loop(value, end_idx, "", new_parts)

      char == "`" ->
        parts = flush_literal(literal, parts)
        {part, end_idx} = parse_backtick_substitution(value, i)
        new_parts = parts ++ [part]
        parse_dq_content_loop(value, end_idx, "", new_parts)

      true ->
        parse_dq_content_loop(value, i + 1, literal <> char, parts)
    end
  end

  defp parse_expansion(value, start) do
    i = start + 1

    if i >= String.length(value) do
      {AST.literal("$"), i}
    else
      char = String.at(value, i)

      cond do
        char == "(" and String.at(value, i + 1) == "(" ->
          parse_arithmetic_expansion(value, start)

        char == "(" ->
          parse_command_substitution(value, start)

        char == "{" ->
          parse_parameter_expansion(value, start)

        char =~ ~r/[a-zA-Z_0-9@*#?$!-]/ ->
          parse_simple_parameter(value, start)

        true ->
          {AST.literal("$"), i}
      end
    end
  end

  defp parse_simple_parameter(value, start) do
    i = start + 1
    char = String.at(value, i)

    if char in [
         "@",
         "*",
         "#",
         "?",
         "$",
         "!",
         "-",
         "0",
         "1",
         "2",
         "3",
         "4",
         "5",
         "6",
         "7",
         "8",
         "9"
       ] do
      {AST.parameter_expansion(char), i + 1}
    else
      {name, end_idx} = collect_var_name(value, i)
      {AST.parameter_expansion(name), end_idx}
    end
  end

  defp collect_var_name(value, start) do
    collect_var_name_loop(value, start, "")
  end

  defp collect_var_name_loop(value, i, acc) do
    char = String.at(value, i)

    if char && char =~ ~r/[a-zA-Z0-9_]/ do
      collect_var_name_loop(value, i + 1, acc <> char)
    else
      {acc, i}
    end
  end

  defp parse_parameter_expansion(value, start) do
    i = start + 2

    cond do
      String.at(value, i) == "!" ->
        parse_indirection_expansion(value, i + 1)

      String.at(value, i) == "#" ->
        parse_length_expansion(value, i + 1)

      true ->
        parse_normal_param_expansion(value, i)
    end
  end

  defp parse_indirection_expansion(value, start) do
    {name, _i} = collect_var_name(value, start)
    end_idx = find_matching_brace(value, start - 2)

    {AST.parameter_expansion(name, %AST.Indirection{}), end_idx + 1}
  end

  defp parse_length_expansion(value, start) do
    next = String.at(value, start)

    if next && not (next =~ ~r/[}:#%\/]/) do
      {name, _i} = collect_var_name(value, start)
      end_idx = find_matching_brace(value, start - 2)
      {AST.parameter_expansion(name, %AST.Length{}), end_idx + 1}
    else
      parse_normal_param_expansion(value, start - 1)
    end
  end

  defp parse_normal_param_expansion(value, start) do
    {name, i} = collect_var_name(value, start)

    if String.at(value, i) == "[" do
      bracket_end = find_matching_bracket(value, i)
      subscript = String.slice(value, (i + 1)..(bracket_end - 1)//1)
      name = name <> "[" <> subscript <> "]"
      i = bracket_end + 1
      parse_param_operation(value, start - 2, name, i)
    else
      parse_param_operation(value, start - 2, name, i)
    end
  end

  defp parse_param_operation(value, brace_start, name, i) do
    end_brace = find_matching_brace(value, brace_start)
    char = String.at(value, i)

    cond do
      char == "}" or char == nil ->
        {AST.parameter_expansion(name), end_brace + 1}

      char == ":" ->
        parse_colon_operation(value, brace_start, name, i)

      char == "-" ->
        parse_default_operation(value, brace_start, name, i, false)

      char == "=" ->
        parse_assign_default_operation(value, brace_start, name, i, false)

      char == "?" ->
        parse_error_operation(value, brace_start, name, i, false)

      char == "+" ->
        parse_alternative_operation(value, brace_start, name, i, false)

      char == "#" ->
        parse_pattern_removal(value, brace_start, name, i, :prefix)

      char == "%" ->
        parse_pattern_removal(value, brace_start, name, i, :suffix)

      char == "/" ->
        parse_pattern_replacement(value, brace_start, name, i)

      char == "^" ->
        parse_case_modification(value, brace_start, name, i, :upper)

      char == "," ->
        parse_case_modification(value, brace_start, name, i, :lower)

      true ->
        {AST.parameter_expansion(name), end_brace + 1}
    end
  end

  defp parse_colon_operation(value, brace_start, name, i) do
    next = String.at(value, i + 1)

    case next do
      "-" -> parse_default_operation(value, brace_start, name, i + 1, true)
      "=" -> parse_assign_default_operation(value, brace_start, name, i + 1, true)
      "?" -> parse_error_operation(value, brace_start, name, i + 1, true)
      "+" -> parse_alternative_operation(value, brace_start, name, i + 1, true)
      _ -> parse_substring_operation(value, brace_start, name, i)
    end
  end

  defp parse_default_operation(value, brace_start, name, i, check_empty) do
    end_brace = find_matching_brace(value, brace_start)
    word_str = String.slice(value, (i + 1)..(end_brace - 1)//1)
    word_parts = parse(word_str)
    word = AST.word(word_parts)
    op = %AST.DefaultValue{word: word, check_empty: check_empty}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_assign_default_operation(value, brace_start, name, i, check_empty) do
    end_brace = find_matching_brace(value, brace_start)
    word_str = String.slice(value, (i + 1)..(end_brace - 1)//1)
    word_parts = parse(word_str)
    word = AST.word(word_parts)
    op = %AST.AssignDefault{word: word, check_empty: check_empty}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_error_operation(value, brace_start, name, i, check_empty) do
    end_brace = find_matching_brace(value, brace_start)
    word_str = String.slice(value, (i + 1)..(end_brace - 1)//1)
    word = if word_str != "", do: AST.word(parse(word_str)), else: nil
    op = %AST.ErrorIfUnset{word: word, check_empty: check_empty}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_alternative_operation(value, brace_start, name, i, check_empty) do
    end_brace = find_matching_brace(value, brace_start)
    word_str = String.slice(value, (i + 1)..(end_brace - 1)//1)
    word_parts = parse(word_str)
    word = AST.word(word_parts)
    op = %AST.UseAlternative{word: word, check_empty: check_empty}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_substring_operation(value, brace_start, name, i) do
    end_brace = find_matching_brace(value, brace_start)
    rest = String.slice(value, (i + 1)..(end_brace - 1)//1)

    {offset_str, length_str} =
      case String.split(rest, ":", parts: 2) do
        [off] -> {off, nil}
        [off, len] -> {off, len}
      end

    offset = parse_substring_value(offset_str)
    length = if length_str, do: parse_substring_value(length_str), else: nil

    op = %AST.Substring{offset: offset, length: length}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_substring_value(str) do
    str = String.trim(str)

    case Integer.parse(str) do
      {num, ""} -> %AST.ArithNumber{value: num}
      _ -> %AST.ArithVariable{name: str}
    end
  end

  defp parse_pattern_removal(value, brace_start, name, i, side) do
    end_brace = find_matching_brace(value, brace_start)
    next = String.at(value, i + 1)

    {greedy, pattern_start} =
      if next == String.at(value, i), do: {true, i + 2}, else: {false, i + 1}

    pattern_str = String.slice(value, pattern_start..(end_brace - 1)//1)
    pattern = AST.word(parse(pattern_str))
    op = %AST.PatternRemoval{pattern: pattern, side: side, greedy: greedy}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_pattern_replacement(value, brace_start, name, i) do
    end_brace = find_matching_brace(value, brace_start)
    next = String.at(value, i + 1)
    {all, start_pos} = if next == "/", do: {true, i + 2}, else: {false, i + 1}

    anchor_char = String.at(value, start_pos)

    {anchor, pattern_start} =
      cond do
        anchor_char == "#" -> {:start, start_pos + 1}
        anchor_char == "%" -> {:end, start_pos + 1}
        true -> {nil, start_pos}
      end

    rest = String.slice(value, pattern_start..(end_brace - 1)//1)

    {pattern_str, replacement_str} =
      case find_pattern_separator(rest) do
        nil ->
          {rest, nil}

        sep_idx ->
          {String.slice(rest, 0..(sep_idx - 1)//1), String.slice(rest, (sep_idx + 1)..-1//1)}
      end

    pattern = AST.word(parse(pattern_str))
    replacement = if replacement_str, do: AST.word(parse(replacement_str)), else: nil

    op = %AST.PatternReplacement{
      pattern: pattern,
      replacement: replacement,
      all: all,
      anchor: anchor
    }

    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp find_pattern_separator(str), do: find_pattern_separator(str, 0, 0)

  defp find_pattern_separator(str, i, _depth) when i >= byte_size(str), do: nil

  defp find_pattern_separator(str, i, depth) do
    char = String.at(str, i)

    cond do
      char == "\\" and i + 1 < String.length(str) ->
        find_pattern_separator(str, i + 2, depth)

      char == "/" and depth == 0 ->
        i

      char == "{" ->
        find_pattern_separator(str, i + 1, depth + 1)

      char == "}" ->
        find_pattern_separator(str, i + 1, depth - 1)

      true ->
        find_pattern_separator(str, i + 1, depth)
    end
  end

  defp parse_case_modification(value, brace_start, name, i, direction) do
    end_brace = find_matching_brace(value, brace_start)
    next = String.at(value, i + 1)
    {all, pattern_start} = if next == String.at(value, i), do: {true, i + 2}, else: {false, i + 1}
    pattern_str = String.slice(value, pattern_start..(end_brace - 1)//1)
    pattern = if pattern_str != "", do: AST.word(parse(pattern_str)), else: nil
    op = %AST.CaseModification{direction: direction, all: all, pattern: pattern}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_command_substitution(value, start) do
    end_paren = find_matching_paren(value, start + 1)
    cmd_str = String.slice(value, (start + 2)..(end_paren - 1)//1)

    body =
      case JustBash.Parser.parse(cmd_str) do
        {:ok, script} -> script
        {:error, _} -> AST.script([])
      end

    {%AST.CommandSubstitution{body: body, legacy: false}, end_paren + 1}
  end

  defp parse_arithmetic_expansion(value, start) do
    end_dparen = find_double_paren_end(value, start + 2)
    expr_str = String.slice(value, (start + 3)..(end_dparen - 1)//1)
    parsed_expr = JustBash.Arithmetic.parse(expr_str)
    expr = %AST.ArithmeticExpression{expression: parsed_expr}

    {AST.arithmetic_expansion(expr), end_dparen + 2}
  end

  defp parse_backtick_substitution(value, start) do
    end_tick = find_backtick_end(value, start + 1)
    cmd_str = String.slice(value, (start + 1)..(end_tick - 1)//1)

    body =
      case JustBash.Parser.parse(cmd_str) do
        {:ok, script} -> script
        {:error, _} -> AST.script([])
      end

    {%AST.CommandSubstitution{body: body, legacy: true}, end_tick + 1}
  end

  defp parse_ansi_c_quoted(value, start) do
    parse_ansi_c_loop(value, start, "")
  end

  defp parse_ansi_c_loop(value, i, acc) when i >= byte_size(value), do: {acc, i}

  defp parse_ansi_c_loop(value, i, acc) do
    char = String.at(value, i)

    cond do
      char == "'" ->
        {acc, i + 1}

      char == "\\" and i + 1 < String.length(value) ->
        next = String.at(value, i + 1)

        case next do
          "n" -> parse_ansi_c_loop(value, i + 2, acc <> "\n")
          "t" -> parse_ansi_c_loop(value, i + 2, acc <> "\t")
          "r" -> parse_ansi_c_loop(value, i + 2, acc <> "\r")
          "\\" -> parse_ansi_c_loop(value, i + 2, acc <> "\\")
          "'" -> parse_ansi_c_loop(value, i + 2, acc <> "'")
          "\"" -> parse_ansi_c_loop(value, i + 2, acc <> "\"")
          "a" -> parse_ansi_c_loop(value, i + 2, acc <> "\a")
          "b" -> parse_ansi_c_loop(value, i + 2, acc <> "\b")
          "e" -> parse_ansi_c_loop(value, i + 2, acc <> "\e")
          "E" -> parse_ansi_c_loop(value, i + 2, acc <> "\e")
          "f" -> parse_ansi_c_loop(value, i + 2, acc <> "\f")
          "v" -> parse_ansi_c_loop(value, i + 2, acc <> "\v")
          _ -> parse_ansi_c_loop(value, i + 1, acc <> char)
        end

      true ->
        parse_ansi_c_loop(value, i + 1, acc <> char)
    end
  end

  defp find_tilde_end(value, start) do
    find_tilde_end_loop(value, start + 1)
  end

  defp find_tilde_end_loop(value, i) do
    char = String.at(value, i)

    if char && char =~ ~r/[a-zA-Z0-9_-]/ do
      find_tilde_end_loop(value, i + 1)
    else
      i
    end
  end

  defp find_glob_bracket_end(value, start) do
    find_glob_bracket_loop(value, start + 1)
  end

  defp find_glob_bracket_loop(value, i) when i >= byte_size(value), do: :error

  defp find_glob_bracket_loop(value, i) do
    char = String.at(value, i)

    cond do
      char == "]" -> {:ok, i}
      char == "\\" and i + 1 < String.length(value) -> find_glob_bracket_loop(value, i + 2)
      true -> find_glob_bracket_loop(value, i + 1)
    end
  end

  defp find_matching_brace(value, start) do
    find_matching_bracket_loop(value, start + 1, 1, "{", "}")
  end

  defp find_matching_paren(value, start) do
    find_matching_bracket_loop(value, start + 1, 1, "(", ")")
  end

  defp find_matching_bracket(value, start) do
    find_matching_bracket_loop(value, start + 1, 1, "[", "]")
  end

  defp find_matching_bracket_loop(value, i, depth, _open, _close)
       when depth == 0 or i >= byte_size(value),
       do: i - 1

  defp find_matching_bracket_loop(value, i, depth, open, close) do
    char = String.at(value, i)

    cond do
      char == open ->
        find_matching_bracket_loop(value, i + 1, depth + 1, open, close)

      char == close ->
        find_matching_bracket_loop(value, i + 1, depth - 1, open, close)

      char == "\\" and i + 1 < String.length(value) ->
        find_matching_bracket_loop(value, i + 2, depth, open, close)

      true ->
        find_matching_bracket_loop(value, i + 1, depth, open, close)
    end
  end

  defp find_double_paren_end(value, start) do
    find_dparen_loop(value, start, 1)
  end

  defp find_dparen_loop(value, i, depth) when depth == 0 or i >= byte_size(value) - 1, do: i - 1

  defp find_dparen_loop(value, i, depth) do
    char = String.at(value, i)
    next = String.at(value, i + 1)

    cond do
      char == "(" and next == "(" -> find_dparen_loop(value, i + 2, depth + 1)
      char == ")" and next == ")" -> find_dparen_loop(value, i + 2, depth - 1)
      true -> find_dparen_loop(value, i + 1, depth)
    end
  end

  defp find_backtick_end(value, start) do
    find_backtick_loop(value, start)
  end

  defp find_backtick_loop(value, i) when i >= byte_size(value), do: i

  defp find_backtick_loop(value, i) do
    char = String.at(value, i)

    cond do
      char == "`" -> i
      char == "\\" and i + 1 < String.length(value) -> find_backtick_loop(value, i + 2)
      true -> find_backtick_loop(value, i + 1)
    end
  end
end
