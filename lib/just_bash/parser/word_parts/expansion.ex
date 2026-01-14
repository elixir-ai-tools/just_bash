defmodule JustBash.Parser.WordParts.Expansion do
  @moduledoc """
  Parses shell expansions: $VAR, ${VAR}, $((expr)), $(cmd), `cmd`.

  Handles all forms of parameter expansion including:
  - Simple: $VAR, ${VAR}
  - Default values: ${VAR:-default}, ${VAR:=default}
  - Substring: ${VAR:offset:length}
  - Pattern removal: ${VAR#pattern}, ${VAR%pattern}
  - Pattern replacement: ${VAR/pattern/replacement}
  - Case modification: ${VAR^^}, ${VAR,,}
  - Length: ${#VAR}
  - Indirection: ${!VAR}
  """

  alias JustBash.AST
  alias JustBash.Parser.WordParts
  alias JustBash.Parser.WordParts.Bracket

  @doc """
  Parse an expansion starting at position `start` (pointing to `$`).
  Returns `{ast_node, end_index}`.
  """
  @spec parse(String.t(), non_neg_integer()) :: {AST.word_part(), non_neg_integer()}
  def parse(value, start) do
    i = start + 1

    if i >= String.length(value) do
      {AST.literal("$"), i}
    else
      dispatch_expansion(String.at(value, i), String.at(value, i + 1), value, start)
    end
  end

  defp dispatch_expansion("(", "(", value, start) do
    parse_arithmetic_expansion(value, start)
  end

  defp dispatch_expansion("(", _, value, start) do
    parse_command_substitution(value, start)
  end

  defp dispatch_expansion("{", _, value, start) do
    parse_parameter_expansion(value, start)
  end

  defp dispatch_expansion(char, _, value, start) when char != nil do
    if char =~ ~r/[a-zA-Z_0-9@*#?$!-]/ do
      parse_simple_parameter(value, start)
    else
      {AST.literal("$"), start + 1}
    end
  end

  defp dispatch_expansion(_, _, _, start) do
    {AST.literal("$"), start + 1}
  end

  @doc """
  Parse a backtick command substitution starting at `start`.
  """
  @spec parse_backtick(String.t(), non_neg_integer()) :: {AST.word_part(), non_neg_integer()}
  def parse_backtick(value, start) do
    end_tick = Bracket.find_backtick_end(value, start + 1)
    cmd_str = String.slice(value, (start + 1)..(end_tick - 1)//1)

    body =
      case JustBash.Parser.parse(cmd_str) do
        {:ok, script} -> script
        {:error, _} -> AST.script([])
      end

    {%AST.CommandSubstitution{body: body, legacy: true}, end_tick + 1}
  end

  # Simple parameter: $VAR, $?, $$, etc.
  defp parse_simple_parameter(value, start) do
    i = start + 1
    char = String.at(value, i)

    special_chars = [
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
    ]

    if char in special_chars do
      {AST.parameter_expansion(char), i + 1}
    else
      {name, end_idx} = collect_var_name(value, i)
      {AST.parameter_expansion(name), end_idx}
    end
  end

  @doc false
  def collect_var_name(value, start) do
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

  # ${...} parameter expansion
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
    end_idx = Bracket.find_matching_brace(value, start - 2)
    {AST.parameter_expansion(name, %AST.Indirection{}), end_idx + 1}
  end

  defp parse_length_expansion(value, start) do
    next = String.at(value, start)

    if next && not (next =~ ~r/[}:#%\/]/) do
      {name, i} = collect_var_name(value, start)

      name =
        if String.at(value, i) == "[" do
          bracket_end = Bracket.find_matching_bracket(value, i)
          subscript = String.slice(value, (i + 1)..(bracket_end - 1)//1)
          name <> "[" <> subscript <> "]"
        else
          name
        end

      end_idx = Bracket.find_matching_brace(value, start - 2)
      {AST.parameter_expansion(name, %AST.Length{}), end_idx + 1}
    else
      parse_normal_param_expansion(value, start - 1)
    end
  end

  defp parse_normal_param_expansion(value, start) do
    {name, i} = collect_var_name(value, start)
    brace_start = start - 1

    if String.at(value, i) == "[" do
      bracket_end = Bracket.find_matching_bracket(value, i)
      subscript = String.slice(value, (i + 1)..(bracket_end - 1)//1)
      name = name <> "[" <> subscript <> "]"
      i = bracket_end + 1
      parse_param_operation(value, brace_start, name, i)
    else
      parse_param_operation(value, brace_start, name, i)
    end
  end

  defp parse_param_operation(value, brace_start, name, i) do
    end_brace = Bracket.find_matching_brace(value, brace_start)
    char = String.at(value, i)
    dispatch_param_operation(char, value, brace_start, name, i, end_brace)
  end

  defp dispatch_param_operation(char, _value, _brace_start, name, _i, end_brace)
       when char == "}" or char == nil do
    {AST.parameter_expansion(name), end_brace + 1}
  end

  defp dispatch_param_operation(":", value, brace_start, name, i, _end_brace) do
    parse_colon_operation(value, brace_start, name, i)
  end

  defp dispatch_param_operation("-", value, brace_start, name, i, _end_brace) do
    parse_default_operation(value, brace_start, name, i, false)
  end

  defp dispatch_param_operation("=", value, brace_start, name, i, _end_brace) do
    parse_assign_default_operation(value, brace_start, name, i, false)
  end

  defp dispatch_param_operation("?", value, brace_start, name, i, _end_brace) do
    parse_error_operation(value, brace_start, name, i, false)
  end

  defp dispatch_param_operation("+", value, brace_start, name, i, _end_brace) do
    parse_alternative_operation(value, brace_start, name, i, false)
  end

  defp dispatch_param_operation("#", value, brace_start, name, i, _end_brace) do
    parse_pattern_removal(value, brace_start, name, i, :prefix)
  end

  defp dispatch_param_operation("%", value, brace_start, name, i, _end_brace) do
    parse_pattern_removal(value, brace_start, name, i, :suffix)
  end

  defp dispatch_param_operation("/", value, brace_start, name, i, _end_brace) do
    parse_pattern_replacement(value, brace_start, name, i)
  end

  defp dispatch_param_operation("^", value, brace_start, name, i, _end_brace) do
    parse_case_modification(value, brace_start, name, i, :upper)
  end

  defp dispatch_param_operation(",", value, brace_start, name, i, _end_brace) do
    parse_case_modification(value, brace_start, name, i, :lower)
  end

  defp dispatch_param_operation(_char, _value, _brace_start, name, _i, end_brace) do
    {AST.parameter_expansion(name), end_brace + 1}
  end

  defp parse_colon_operation(value, brace_start, name, i) do
    case String.at(value, i + 1) do
      "-" -> parse_default_operation(value, brace_start, name, i + 1, true)
      "=" -> parse_assign_default_operation(value, brace_start, name, i + 1, true)
      "?" -> parse_error_operation(value, brace_start, name, i + 1, true)
      "+" -> parse_alternative_operation(value, brace_start, name, i + 1, true)
      _ -> parse_substring_operation(value, brace_start, name, i)
    end
  end

  defp parse_default_operation(value, brace_start, name, i, check_empty) do
    end_brace = Bracket.find_matching_brace(value, brace_start)
    word_str = String.slice(value, (i + 1)..(end_brace - 1)//1)
    word_parts = WordParts.parse(word_str)
    word = AST.word(word_parts)
    op = %AST.DefaultValue{word: word, check_empty: check_empty}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_assign_default_operation(value, brace_start, name, i, check_empty) do
    end_brace = Bracket.find_matching_brace(value, brace_start)
    word_str = String.slice(value, (i + 1)..(end_brace - 1)//1)
    word_parts = WordParts.parse(word_str)
    word = AST.word(word_parts)
    op = %AST.AssignDefault{word: word, check_empty: check_empty}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_error_operation(value, brace_start, name, i, check_empty) do
    end_brace = Bracket.find_matching_brace(value, brace_start)
    word_str = String.slice(value, (i + 1)..(end_brace - 1)//1)
    word = if word_str != "", do: AST.word(WordParts.parse(word_str)), else: nil
    op = %AST.ErrorIfUnset{word: word, check_empty: check_empty}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_alternative_operation(value, brace_start, name, i, check_empty) do
    end_brace = Bracket.find_matching_brace(value, brace_start)
    word_str = String.slice(value, (i + 1)..(end_brace - 1)//1)
    word_parts = WordParts.parse(word_str)
    word = AST.word(word_parts)
    op = %AST.UseAlternative{word: word, check_empty: check_empty}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_substring_operation(value, brace_start, name, i) do
    end_brace = Bracket.find_matching_brace(value, brace_start)
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
    end_brace = Bracket.find_matching_brace(value, brace_start)
    next = String.at(value, i + 1)

    {greedy, pattern_start} =
      if next == String.at(value, i), do: {true, i + 2}, else: {false, i + 1}

    pattern_str = String.slice(value, pattern_start..(end_brace - 1)//1)
    pattern = AST.word(WordParts.parse(pattern_str))
    op = %AST.PatternRemoval{pattern: pattern, side: side, greedy: greedy}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_pattern_replacement(value, brace_start, name, i) do
    end_brace = Bracket.find_matching_brace(value, brace_start)
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

    pattern = AST.word(WordParts.parse(pattern_str))
    replacement = if replacement_str, do: AST.word(WordParts.parse(replacement_str)), else: nil

    op = %AST.PatternReplacement{
      pattern: pattern,
      replacement: replacement,
      all: all,
      anchor: anchor
    }

    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp find_pattern_separator(str) do
    find_pattern_separator(str, 0, String.length(str), 0)
  end

  defp find_pattern_separator(_str, i, len, _depth) when i >= len, do: nil

  defp find_pattern_separator(str, i, len, depth) do
    char = String.at(str, i)

    cond do
      char == "\\" and i + 1 < len -> find_pattern_separator(str, i + 2, len, depth)
      char == "/" and depth == 0 -> i
      char == "{" -> find_pattern_separator(str, i + 1, len, depth + 1)
      char == "}" -> find_pattern_separator(str, i + 1, len, depth - 1)
      true -> find_pattern_separator(str, i + 1, len, depth)
    end
  end

  defp parse_case_modification(value, brace_start, name, i, direction) do
    end_brace = Bracket.find_matching_brace(value, brace_start)
    next = String.at(value, i + 1)
    {all, pattern_start} = if next == String.at(value, i), do: {true, i + 2}, else: {false, i + 1}
    pattern_str = String.slice(value, pattern_start..(end_brace - 1)//1)
    pattern = if pattern_str != "", do: AST.word(WordParts.parse(pattern_str)), else: nil
    op = %AST.CaseModification{direction: direction, all: all, pattern: pattern}
    {AST.parameter_expansion(name, op), end_brace + 1}
  end

  defp parse_command_substitution(value, start) do
    end_paren = Bracket.find_matching_paren(value, start + 1)
    cmd_str = String.slice(value, (start + 2)..(end_paren - 1)//1)

    body =
      case JustBash.Parser.parse(cmd_str) do
        {:ok, script} -> script
        {:error, _} -> AST.script([])
      end

    {%AST.CommandSubstitution{body: body, legacy: false}, end_paren + 1}
  end

  defp parse_arithmetic_expansion(value, start) do
    end_dparen = Bracket.find_double_paren_end(value, start + 3)
    expr_str = String.slice(value, (start + 3)..(end_dparen - 1)//1)
    parsed_expr = JustBash.Arithmetic.parse(expr_str)
    expr = %AST.ArithmeticExpression{expression: parsed_expr}
    {AST.arithmetic_expansion(expr), end_dparen + 2}
  end
end
