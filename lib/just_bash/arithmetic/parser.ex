defmodule JustBash.Arithmetic.Parser do
  @moduledoc """
  Recursive descent parser for bash arithmetic expressions.

  Parses arithmetic expression strings into AST nodes.
  Handles operator precedence through the grammar structure:

  Expression precedence (lowest to highest):
  1. Comma (,)
  2. Ternary (?:)
  3. Logical OR (||)
  4. Logical AND (&&)
  5. Bitwise OR (|)
  6. Bitwise XOR (^)
  7. Bitwise AND (&)
  8. Equality (==, !=)
  9. Relational (<, <=, >, >=)
  10. Shift (<<, >>)
  11. Additive (+, -)
  12. Multiplicative (*, /, %)
  13. Power (**)
  14. Unary (!, ~, -, +, ++, --)
  15. Postfix (++, --)
  16. Primary (numbers, variables, groups)
  """

  alias JustBash.AST

  @doc """
  Parse an arithmetic expression string into an AST.
  """
  @spec parse(String.t()) :: AST.arith_expr()
  def parse(expr_str) do
    expr_str = String.trim(expr_str)

    if expr_str == "" do
      %AST.ArithNumber{value: 0}
    else
      len = String.length(expr_str)
      {ast, _rest} = parse_expr(expr_str, len, 0)
      ast
    end
  end

  # Entry point - comma operator (lowest precedence)
  defp parse_expr(str, len, pos) do
    parse_comma(str, len, pos)
  end

  defp parse_comma(str, len, pos) do
    {left, pos} = parse_ternary(str, len, pos)
    parse_comma_loop(str, len, pos, left)
  end

  defp parse_comma_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    if pos < len and String.at(str, pos) == "," do
      {right, pos} = parse_ternary(str, len, pos + 1)
      parse_comma_loop(str, len, pos, %AST.ArithBinary{operator: ",", left: left, right: right})
    else
      {left, pos}
    end
  end

  # Ternary operator: cond ? then : else
  defp parse_ternary(str, len, pos) do
    {cond_expr, pos} = parse_logical_or(str, len, pos)
    pos = skip_whitespace(str, len, pos)

    if pos < len and String.at(str, pos) == "?" do
      {consequent, pos} = parse_ternary(str, len, pos + 1)
      pos = skip_whitespace(str, len, pos)

      if pos < len and String.at(str, pos) == ":" do
        {alternate, pos} = parse_ternary(str, len, pos + 1)

        {%AST.ArithTernary{condition: cond_expr, consequent: consequent, alternate: alternate},
         pos}
      else
        {cond_expr, pos}
      end
    else
      {cond_expr, pos}
    end
  end

  # Logical OR: ||
  defp parse_logical_or(str, len, pos) do
    {left, pos} = parse_logical_and(str, len, pos)
    parse_logical_or_loop(str, len, pos, left)
  end

  defp parse_logical_or_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    if match_op?(str, len, pos, "||") do
      {right, pos} = parse_logical_and(str, len, pos + 2)

      parse_logical_or_loop(str, len, pos, %AST.ArithBinary{
        operator: "||",
        left: left,
        right: right
      })
    else
      {left, pos}
    end
  end

  # Logical AND: &&
  defp parse_logical_and(str, len, pos) do
    {left, pos} = parse_bitwise_or(str, len, pos)
    parse_logical_and_loop(str, len, pos, left)
  end

  defp parse_logical_and_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    if match_op?(str, len, pos, "&&") do
      {right, pos} = parse_bitwise_or(str, len, pos + 2)

      parse_logical_and_loop(str, len, pos, %AST.ArithBinary{
        operator: "&&",
        left: left,
        right: right
      })
    else
      {left, pos}
    end
  end

  # Bitwise OR: |
  defp parse_bitwise_or(str, len, pos) do
    {left, pos} = parse_bitwise_xor(str, len, pos)
    parse_bitwise_or_loop(str, len, pos, left)
  end

  defp parse_bitwise_or_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    if pos < len and String.at(str, pos) == "|" and
         not match_op?(str, len, pos, "||") do
      {right, pos} = parse_bitwise_xor(str, len, pos + 1)

      parse_bitwise_or_loop(str, len, pos, %AST.ArithBinary{
        operator: "|",
        left: left,
        right: right
      })
    else
      {left, pos}
    end
  end

  # Bitwise XOR: ^
  defp parse_bitwise_xor(str, len, pos) do
    {left, pos} = parse_bitwise_and(str, len, pos)
    parse_bitwise_xor_loop(str, len, pos, left)
  end

  defp parse_bitwise_xor_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    if pos < len and String.at(str, pos) == "^" do
      {right, pos} = parse_bitwise_and(str, len, pos + 1)

      parse_bitwise_xor_loop(str, len, pos, %AST.ArithBinary{
        operator: "^",
        left: left,
        right: right
      })
    else
      {left, pos}
    end
  end

  # Bitwise AND: &
  defp parse_bitwise_and(str, len, pos) do
    {left, pos} = parse_equality(str, len, pos)
    parse_bitwise_and_loop(str, len, pos, left)
  end

  defp parse_bitwise_and_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    if pos < len and String.at(str, pos) == "&" and
         not match_op?(str, len, pos, "&&") do
      {right, pos} = parse_equality(str, len, pos + 1)

      parse_bitwise_and_loop(str, len, pos, %AST.ArithBinary{
        operator: "&",
        left: left,
        right: right
      })
    else
      {left, pos}
    end
  end

  # Equality: ==, !=
  defp parse_equality(str, len, pos) do
    {left, pos} = parse_relational(str, len, pos)
    parse_equality_loop(str, len, pos, left)
  end

  defp parse_equality_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    cond do
      match_op?(str, len, pos, "==") ->
        {right, pos} = parse_relational(str, len, pos + 2)

        parse_equality_loop(str, len, pos, %AST.ArithBinary{
          operator: "==",
          left: left,
          right: right
        })

      match_op?(str, len, pos, "!=") ->
        {right, pos} = parse_relational(str, len, pos + 2)

        parse_equality_loop(str, len, pos, %AST.ArithBinary{
          operator: "!=",
          left: left,
          right: right
        })

      true ->
        {left, pos}
    end
  end

  # Relational: <, <=, >, >=
  defp parse_relational(str, len, pos) do
    {left, pos} = parse_shift(str, len, pos)
    parse_relational_loop(str, len, pos, left)
  end

  defp parse_relational_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    case detect_relational_op(str, len, pos) do
      {op, op_len} ->
        {right, pos} = parse_shift(str, len, pos + op_len)

        parse_relational_loop(str, len, pos, %AST.ArithBinary{
          operator: op,
          left: left,
          right: right
        })

      nil ->
        {left, pos}
    end
  end

  defp detect_relational_op(str, len, pos) do
    cond do
      match_op?(str, len, pos, "<=") -> {"<=", 2}
      match_op?(str, len, pos, ">=") -> {">=", 2}
      less_than_op?(str, len, pos) -> {"<", 1}
      greater_than_op?(str, len, pos) -> {">", 1}
      true -> nil
    end
  end

  defp less_than_op?(str, len, pos) do
    pos < len and String.at(str, pos) == "<" and not match_op?(str, len, pos, "<<")
  end

  defp greater_than_op?(str, len, pos) do
    pos < len and String.at(str, pos) == ">" and not match_op?(str, len, pos, ">>")
  end

  # Shift: <<, >>
  defp parse_shift(str, len, pos) do
    {left, pos} = parse_additive(str, len, pos)
    parse_shift_loop(str, len, pos, left)
  end

  defp parse_shift_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    cond do
      match_op?(str, len, pos, "<<") ->
        {right, pos} = parse_additive(str, len, pos + 2)

        parse_shift_loop(str, len, pos, %AST.ArithBinary{operator: "<<", left: left, right: right})

      match_op?(str, len, pos, ">>") ->
        {right, pos} = parse_additive(str, len, pos + 2)

        parse_shift_loop(str, len, pos, %AST.ArithBinary{operator: ">>", left: left, right: right})

      true ->
        {left, pos}
    end
  end

  # Additive: +, -
  defp parse_additive(str, len, pos) do
    {left, pos} = parse_multiplicative(str, len, pos)
    parse_additive_loop(str, len, pos, left)
  end

  defp parse_additive_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    case detect_additive_op(str, len, pos) do
      op when op != nil ->
        {right, pos} = parse_multiplicative(str, len, pos + 1)

        parse_additive_loop(str, len, pos, %AST.ArithBinary{
          operator: op,
          left: left,
          right: right
        })

      nil ->
        {left, pos}
    end
  end

  defp detect_additive_op(str, len, pos) do
    cond do
      additive_plus_op?(str, len, pos) -> "+"
      additive_minus_op?(str, len, pos) -> "-"
      true -> nil
    end
  end

  defp additive_plus_op?(str, len, pos) do
    pos < len and String.at(str, pos) == "+" and
      not match_op?(str, len, pos, "++") and not match_op?(str, len, pos, "+=")
  end

  defp additive_minus_op?(str, len, pos) do
    pos < len and String.at(str, pos) == "-" and
      not match_op?(str, len, pos, "--") and not match_op?(str, len, pos, "-=")
  end

  # Multiplicative: *, /, %, **
  defp parse_multiplicative(str, len, pos) do
    {left, pos} = parse_power(str, len, pos)
    parse_multiplicative_loop(str, len, pos, left)
  end

  defp parse_multiplicative_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    cond do
      match_op?(str, len, pos, "**") ->
        {right, pos} = parse_power(str, len, pos + 2)

        parse_multiplicative_loop(str, len, pos, %AST.ArithBinary{
          operator: "**",
          left: left,
          right: right
        })

      pos < len and String.at(str, pos) == "*" ->
        {right, pos} = parse_power(str, len, pos + 1)

        parse_multiplicative_loop(str, len, pos, %AST.ArithBinary{
          operator: "*",
          left: left,
          right: right
        })

      pos < len and String.at(str, pos) == "/" ->
        {right, pos} = parse_power(str, len, pos + 1)

        parse_multiplicative_loop(str, len, pos, %AST.ArithBinary{
          operator: "/",
          left: left,
          right: right
        })

      pos < len and String.at(str, pos) == "%" ->
        {right, pos} = parse_power(str, len, pos + 1)

        parse_multiplicative_loop(str, len, pos, %AST.ArithBinary{
          operator: "%",
          left: left,
          right: right
        })

      true ->
        {left, pos}
    end
  end

  # Power: ** (right associative)
  defp parse_power(str, len, pos) do
    {left, pos} = parse_unary(str, len, pos)
    pos = skip_whitespace(str, len, pos)

    if match_op?(str, len, pos, "**") do
      {right, pos} = parse_power(str, len, pos + 2)
      {%AST.ArithBinary{operator: "**", left: left, right: right}, pos}
    else
      {left, pos}
    end
  end

  # Unary prefix: !, ~, -, +, ++, --
  defp parse_unary(str, len, pos) do
    pos = skip_whitespace(str, len, pos)

    case detect_unary_op(str, len, pos) do
      {op, op_len} ->
        {operand, pos} = parse_unary(str, len, pos + op_len)
        {%AST.ArithUnary{operator: op, operand: operand, prefix: true}, pos}

      nil ->
        parse_postfix(str, len, pos)
    end
  end

  defp detect_unary_op(str, len, pos) do
    cond do
      match_op?(str, len, pos, "++") -> {"++", 2}
      match_op?(str, len, pos, "--") -> {"--", 2}
      single_char_unary?(str, len, pos, "!") -> {"!", 1}
      single_char_unary?(str, len, pos, "~") -> {"~", 1}
      unary_minus_op?(str, len, pos) -> {"-", 1}
      unary_plus_op?(str, len, pos) -> {"+", 1}
      true -> nil
    end
  end

  defp single_char_unary?(str, len, pos, char) do
    pos < len and String.at(str, pos) == char
  end

  defp unary_minus_op?(str, len, pos) do
    pos < len and String.at(str, pos) == "-" and not match_op?(str, len, pos, "--")
  end

  defp unary_plus_op?(str, len, pos) do
    pos < len and String.at(str, pos) == "+" and not match_op?(str, len, pos, "++")
  end

  # Postfix: ++, --
  defp parse_postfix(str, len, pos) do
    {primary, pos} = parse_primary(str, len, pos)
    parse_postfix_ops(str, len, pos, primary)
  end

  defp parse_postfix_ops(str, len, pos, expr) do
    pos = skip_whitespace(str, len, pos)

    cond do
      match_op?(str, len, pos, "++") ->
        {%AST.ArithUnary{operator: "++", operand: expr, prefix: false}, pos + 2}

      match_op?(str, len, pos, "--") ->
        {%AST.ArithUnary{operator: "--", operand: expr, prefix: false}, pos + 2}

      true ->
        {expr, pos}
    end
  end

  # Primary: numbers, variables, groups
  defp parse_primary(str, len, pos) do
    pos = skip_whitespace(str, len, pos)

    cond do
      pos >= len ->
        {%AST.ArithNumber{value: 0}, pos}

      String.at(str, pos) == "(" ->
        {inner, pos} = parse_expr(str, len, pos + 1)
        pos = skip_whitespace(str, len, pos)

        pos =
          if pos < len and String.at(str, pos) == ")" do
            pos + 1
          else
            pos
          end

        {%AST.ArithGroup{expression: inner}, pos}

      digit?(str, pos) ->
        parse_number(str, len, pos)

      var_start?(str, pos) ->
        parse_variable_or_assignment(str, len, pos)

      String.at(str, pos) == "$" ->
        parse_dollar_var(str, len, pos)

      true ->
        {%AST.ArithNumber{value: 0}, pos}
    end
  end

  # Number parsing
  defp parse_number(str, len, pos) do
    {num_str, pos} = collect_number(str, len, pos, "")
    value = parse_number_value(num_str)
    {%AST.ArithNumber{value: value}, pos}
  end

  defp collect_number(_str, len, pos, acc) when pos >= len, do: {acc, pos}

  defp collect_number(str, len, pos, acc) do
    char = String.at(str, pos)

    if alnum?(char) or char == "#" or char == "x" or char == "X" do
      collect_number(str, len, pos + 1, acc <> char)
    else
      {acc, pos}
    end
  end

  defp parse_number_value("0x" <> hex_digits), do: parse_int_with_base(hex_digits, 16)
  defp parse_number_value("0X" <> hex_digits), do: parse_int_with_base(hex_digits, 16)

  defp parse_number_value("0" <> rest = num_str) when byte_size(rest) > 0 do
    if String.contains?(num_str, "#") do
      parse_custom_base(num_str)
    else
      parse_int_with_base(rest, 8)
    end
  end

  defp parse_number_value(num_str) do
    if String.contains?(num_str, "#") do
      parse_custom_base(num_str)
    else
      parse_int_with_base(num_str, 10)
    end
  end

  defp parse_int_with_base(str, base) do
    case Integer.parse(str, base) do
      {val, _} -> val
      :error -> 0
    end
  end

  defp parse_custom_base(num_str) do
    [base_str, val_str] = String.split(num_str, "#", parts: 2)

    case Integer.parse(base_str) do
      {base, _} when base >= 2 and base <= 64 -> parse_base_n(val_str, base)
      _ -> 0
    end
  end

  defp parse_base_n(val_str, base) do
    digits = String.graphemes(val_str)

    Enum.reduce_while(digits, 0, fn char, acc ->
      digit = digit_value(char)

      if digit < base do
        {:cont, acc * base + digit}
      else
        {:halt, 0}
      end
    end)
  end

  defp digit_value(<<c>>) when c >= ?0 and c <= ?9, do: c - ?0
  defp digit_value(<<c>>) when c >= ?a and c <= ?z, do: c - ?a + 10
  defp digit_value(<<c>>) when c >= ?A and c <= ?Z, do: c - ?A + 36
  defp digit_value("@"), do: 62
  defp digit_value("_"), do: 63
  defp digit_value(_), do: 999

  # Variable and assignment parsing
  defp parse_variable_or_assignment(str, len, pos) do
    {name, pos} = collect_var_name(str, len, pos, "")
    pos = skip_whitespace(str, len, pos)

    if match_assignment_op?(str, len, pos) do
      {op, op_len} = get_assignment_op(str, len, pos)
      {value, pos} = parse_ternary(str, len, pos + op_len)
      {%AST.ArithAssignment{operator: op, variable: name, value: value}, pos}
    else
      {%AST.ArithVariable{name: name}, pos}
    end
  end

  defp match_assignment_op?(str, len, pos) do
    assignment_ops = ["<<=", ">>=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "="]

    Enum.any?(assignment_ops, fn op ->
      match_op?(str, len, pos, op) and not match_op?(str, len, pos, "==")
    end)
  end

  @assignment_ops_by_length [
    {"<<=", 3},
    {">>=", 3},
    {"+=", 2},
    {"-=", 2},
    {"*=", 2},
    {"/=", 2},
    {"%=", 2},
    {"&=", 2},
    {"|=", 2},
    {"^=", 2}
  ]

  defp get_assignment_op(str, len, pos) do
    Enum.find(@assignment_ops_by_length, fn {op, _len} -> match_op?(str, len, pos, op) end)
    |> case do
      {op, op_len} -> {op, op_len}
      nil -> get_simple_assignment(str, len, pos)
    end
  end

  defp get_simple_assignment(str, len, pos) do
    if match_op?(str, len, pos, "=") and not match_op?(str, len, pos, "==") do
      {"=", 1}
    else
      {"=", 1}
    end
  end

  defp parse_dollar_var(str, len, pos) do
    pos = pos + 1

    if pos < len and String.at(str, pos) == "{" do
      {name, pos} = collect_until_brace(str, len, pos + 1, "")
      {%AST.ArithVariable{name: name}, pos}
    else
      {name, pos} = collect_var_name(str, len, pos, "")
      {%AST.ArithVariable{name: name}, pos}
    end
  end

  defp collect_until_brace(_str, len, pos, acc) when pos >= len, do: {acc, pos}

  defp collect_until_brace(str, len, pos, acc) do
    char = String.at(str, pos)

    if char == "}" do
      {acc, pos + 1}
    else
      collect_until_brace(str, len, pos + 1, acc <> char)
    end
  end

  defp collect_var_name(_str, len, pos, acc) when pos >= len, do: {acc, pos}

  defp collect_var_name(str, len, pos, acc) do
    char = String.at(str, pos)

    if var_char?(char, acc == "") do
      collect_var_name(str, len, pos + 1, acc <> char)
    else
      {acc, pos}
    end
  end

  # Character classification helpers
  defp var_char?(<<c>>, _is_first) when c >= ?a and c <= ?z, do: true
  defp var_char?(<<c>>, _is_first) when c >= ?A and c <= ?Z, do: true
  defp var_char?("_", _is_first), do: true
  defp var_char?(<<c>>, false) when c >= ?0 and c <= ?9, do: true
  defp var_char?(_, _), do: false

  defp var_start?(str, pos) do
    char = String.at(str, pos)
    var_char?(char, true)
  end

  defp digit?(str, pos) do
    char = String.at(str, pos)
    char >= "0" and char <= "9"
  end

  defp alnum?(char) do
    (char >= "0" and char <= "9") or
      (char >= "a" and char <= "z") or
      (char >= "A" and char <= "Z")
  end

  defp skip_whitespace(_str, len, pos) when pos >= len, do: pos

  defp skip_whitespace(str, len, pos) do
    char = String.at(str, pos)

    if char in [" ", "\t", "\n", "\r"] do
      skip_whitespace(str, len, pos + 1)
    else
      pos
    end
  end

  defp match_op?(str, len, pos, op) do
    op_len = String.length(op)
    pos + op_len <= len and String.slice(str, pos, op_len) == op
  end
end
