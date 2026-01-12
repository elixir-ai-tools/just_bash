defmodule JustBash.Arithmetic do
  @moduledoc """
  Arithmetic expression parsing and evaluation for bash.

  Supports:
  - Basic operators: +, -, *, /, %
  - Comparison operators: <, <=, >, >=, ==, !=
  - Bitwise operators: &, |, ^, ~, <<, >>
  - Logical operators: &&, ||, !
  - Assignment operators: =, +=, -=, etc.
  - Pre/post increment/decrement: ++, --
  - Ternary operator: ? :
  - Parentheses for grouping
  - Variable references
  """

  alias JustBash.AST

  @doc """
  Parse an arithmetic expression string into an AST.
  """
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

  @doc """
  Evaluate an arithmetic AST in the given environment.
  Returns {result, updated_env}.
  """
  def evaluate(ast, env) do
    eval_expr(ast, env)
  end

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

  defp parse_bitwise_or(str, len, pos) do
    {left, pos} = parse_bitwise_xor(str, len, pos)
    parse_bitwise_or_loop(str, len, pos, left)
  end

  defp parse_bitwise_or_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    if pos < len and String.at(str, pos) == "|" and
         !match_op?(str, len, pos, "||") do
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

  defp parse_bitwise_and(str, len, pos) do
    {left, pos} = parse_equality(str, len, pos)
    parse_bitwise_and_loop(str, len, pos, left)
  end

  defp parse_bitwise_and_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    if pos < len and String.at(str, pos) == "&" and
         !match_op?(str, len, pos, "&&") do
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

  defp parse_relational(str, len, pos) do
    {left, pos} = parse_shift(str, len, pos)
    parse_relational_loop(str, len, pos, left)
  end

  defp parse_relational_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    cond do
      match_op?(str, len, pos, "<=") ->
        {right, pos} = parse_shift(str, len, pos + 2)

        parse_relational_loop(str, len, pos, %AST.ArithBinary{
          operator: "<=",
          left: left,
          right: right
        })

      match_op?(str, len, pos, ">=") ->
        {right, pos} = parse_shift(str, len, pos + 2)

        parse_relational_loop(str, len, pos, %AST.ArithBinary{
          operator: ">=",
          left: left,
          right: right
        })

      pos < len and String.at(str, pos) == "<" and !match_op?(str, len, pos, "<<") ->
        {right, pos} = parse_shift(str, len, pos + 1)

        parse_relational_loop(str, len, pos, %AST.ArithBinary{
          operator: "<",
          left: left,
          right: right
        })

      pos < len and String.at(str, pos) == ">" and !match_op?(str, len, pos, ">>") ->
        {right, pos} = parse_shift(str, len, pos + 1)

        parse_relational_loop(str, len, pos, %AST.ArithBinary{
          operator: ">",
          left: left,
          right: right
        })

      true ->
        {left, pos}
    end
  end

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

  defp parse_additive(str, len, pos) do
    {left, pos} = parse_multiplicative(str, len, pos)
    parse_additive_loop(str, len, pos, left)
  end

  defp parse_additive_loop(str, len, pos, left) do
    pos = skip_whitespace(str, len, pos)

    cond do
      pos < len and String.at(str, pos) == "+" and !match_op?(str, len, pos, "++") and
          !match_op?(str, len, pos, "+=") ->
        {right, pos} = parse_multiplicative(str, len, pos + 1)

        parse_additive_loop(str, len, pos, %AST.ArithBinary{
          operator: "+",
          left: left,
          right: right
        })

      pos < len and String.at(str, pos) == "-" and !match_op?(str, len, pos, "--") and
          !match_op?(str, len, pos, "-=") ->
        {right, pos} = parse_multiplicative(str, len, pos + 1)

        parse_additive_loop(str, len, pos, %AST.ArithBinary{
          operator: "-",
          left: left,
          right: right
        })

      true ->
        {left, pos}
    end
  end

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

  defp parse_unary(str, len, pos) do
    pos = skip_whitespace(str, len, pos)

    cond do
      match_op?(str, len, pos, "++") ->
        {operand, pos} = parse_unary(str, len, pos + 2)
        {%AST.ArithUnary{operator: "++", operand: operand, prefix: true}, pos}

      match_op?(str, len, pos, "--") ->
        {operand, pos} = parse_unary(str, len, pos + 2)
        {%AST.ArithUnary{operator: "--", operand: operand, prefix: true}, pos}

      pos < len and String.at(str, pos) == "!" ->
        {operand, pos} = parse_unary(str, len, pos + 1)
        {%AST.ArithUnary{operator: "!", operand: operand, prefix: true}, pos}

      pos < len and String.at(str, pos) == "~" ->
        {operand, pos} = parse_unary(str, len, pos + 1)
        {%AST.ArithUnary{operator: "~", operand: operand, prefix: true}, pos}

      pos < len and String.at(str, pos) == "-" and !match_op?(str, len, pos, "--") ->
        {operand, pos} = parse_unary(str, len, pos + 1)
        {%AST.ArithUnary{operator: "-", operand: operand, prefix: true}, pos}

      pos < len and String.at(str, pos) == "+" and !match_op?(str, len, pos, "++") ->
        {operand, pos} = parse_unary(str, len, pos + 1)
        {%AST.ArithUnary{operator: "+", operand: operand, prefix: true}, pos}

      true ->
        parse_postfix(str, len, pos)
    end
  end

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

  defp parse_number_value(num_str) do
    cond do
      String.starts_with?(num_str, "0x") or String.starts_with?(num_str, "0X") ->
        case Integer.parse(String.slice(num_str, 2..-1//1), 16) do
          {val, _} -> val
          :error -> 0
        end

      String.starts_with?(num_str, "0") and byte_size(num_str) > 1 and
          !String.contains?(num_str, "#") ->
        case Integer.parse(String.slice(num_str, 1..-1//1), 8) do
          {val, _} -> val
          :error -> 0
        end

      String.contains?(num_str, "#") ->
        [base_str, val_str] = String.split(num_str, "#", parts: 2)

        case Integer.parse(base_str) do
          {base, _} when base >= 2 and base <= 64 ->
            parse_base_n(val_str, base)

          _ ->
            0
        end

      true ->
        case Integer.parse(num_str) do
          {val, _} -> val
          :error -> 0
        end
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

  defp digit_value(char) do
    cond do
      char >= "0" and char <= "9" -> String.to_integer(char)
      char >= "a" and char <= "z" -> :binary.first(char) - ?a + 10
      char >= "A" and char <= "Z" -> :binary.first(char) - ?A + 36
      char == "@" -> 62
      char == "_" -> 63
      true -> 999
    end
  end

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

  defp get_assignment_op(str, len, pos) do
    cond do
      match_op?(str, len, pos, "<<=") -> {"<<=", 3}
      match_op?(str, len, pos, ">>=") -> {">>=", 3}
      match_op?(str, len, pos, "+=") -> {"+=", 2}
      match_op?(str, len, pos, "-=") -> {"-=", 2}
      match_op?(str, len, pos, "*=") -> {"*=", 2}
      match_op?(str, len, pos, "/=") -> {"/=", 2}
      match_op?(str, len, pos, "%=") -> {"%=", 2}
      match_op?(str, len, pos, "&=") -> {"&=", 2}
      match_op?(str, len, pos, "|=") -> {"|=", 2}
      match_op?(str, len, pos, "^=") -> {"^=", 2}
      match_op?(str, len, pos, "=") and not match_op?(str, len, pos, "==") -> {"=", 1}
      true -> {"=", 1}
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

  defp var_char?(char, is_first) do
    cond do
      char >= "a" and char <= "z" -> true
      char >= "A" and char <= "Z" -> true
      char == "_" -> true
      not is_first and char >= "0" and char <= "9" -> true
      true -> false
    end
  end

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

  defp eval_expr(%AST.ArithNumber{value: value}, env) do
    {value, env}
  end

  defp eval_expr(%AST.ArithVariable{name: name}, env) do
    value = resolve_variable(env, name)
    {value, env}
  end

  defp eval_expr(%AST.ArithGroup{expression: expr}, env) do
    eval_expr(expr, env)
  end

  defp eval_expr(%AST.ArithBinary{operator: op, left: left, right: right}, env) do
    case op do
      "||" ->
        {left_val, env} = eval_expr(left, env)
        if left_val != 0, do: {1, env}, else: do_logical_or(right, env)

      "&&" ->
        {left_val, env} = eval_expr(left, env)
        if left_val == 0, do: {0, env}, else: do_logical_and(right, env)

      _ ->
        {left_val, env} = eval_expr(left, env)
        {right_val, env} = eval_expr(right, env)
        {apply_binary_op(op, left_val, right_val), env}
    end
  end

  defp eval_expr(%AST.ArithUnary{operator: op, operand: operand, prefix: prefix}, env) do
    case op do
      "++" ->
        do_increment(operand, env, prefix, 1)

      "--" ->
        do_increment(operand, env, prefix, -1)

      _ ->
        {val, env} = eval_expr(operand, env)
        {apply_unary_op(op, val), env}
    end
  end

  defp eval_expr(%AST.ArithTernary{condition: cond, consequent: cons, alternate: alt}, env) do
    {cond_val, env} = eval_expr(cond, env)

    if cond_val != 0 do
      eval_expr(cons, env)
    else
      eval_expr(alt, env)
    end
  end

  defp eval_expr(%AST.ArithAssignment{operator: op, variable: var, value: value}, env) do
    {val, env} = eval_expr(value, env)
    current = resolve_variable(env, var)
    new_val = apply_assignment_op(op, current, val)
    env = Map.put(env, var, to_string(new_val))
    {new_val, env}
  end

  defp eval_expr(%AST.ArithmeticExpansion{expression: expr}, env) do
    eval_expr(expr, env)
  end

  defp eval_expr(_, env), do: {0, env}

  defp do_logical_or(right, env) do
    {right_val, env} = eval_expr(right, env)
    {if(right_val != 0, do: 1, else: 0), env}
  end

  defp do_logical_and(right, env) do
    {right_val, env} = eval_expr(right, env)
    {if(right_val != 0, do: 1, else: 0), env}
  end

  defp do_increment(%AST.ArithVariable{name: name}, env, prefix, delta) do
    current = resolve_variable(env, name)
    new_val = current + delta
    env = Map.put(env, name, to_string(new_val))

    if prefix do
      {new_val, env}
    else
      {current, env}
    end
  end

  defp do_increment(operand, env, _prefix, _delta) do
    eval_expr(operand, env)
  end

  defp resolve_variable(env, name) do
    case Map.get(env, name) do
      nil -> 0
      "" -> 0
      val when is_binary(val) -> parse_int_or_resolve(env, val)
      val when is_integer(val) -> val
    end
  end

  defp parse_int_or_resolve(env, val) do
    case Integer.parse(String.trim(val)) do
      {num, ""} ->
        num

      _ ->
        if Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, val) do
          resolve_variable(env, val)
        else
          0
        end
    end
  end

  defp apply_binary_op(op, left, right) do
    case op do
      "+" -> left + right
      "-" -> left - right
      "*" -> left * right
      "/" -> if right != 0, do: div(left, right), else: 0
      "%" -> if right != 0, do: rem(left, right), else: 0
      "**" -> if right >= 0, do: trunc(:math.pow(left, right)), else: 0
      "<<" -> Bitwise.bsl(left, right)
      ">>" -> Bitwise.bsr(left, right)
      "<" -> if left < right, do: 1, else: 0
      "<=" -> if left <= right, do: 1, else: 0
      ">" -> if left > right, do: 1, else: 0
      ">=" -> if left >= right, do: 1, else: 0
      "==" -> if left == right, do: 1, else: 0
      "!=" -> if left != right, do: 1, else: 0
      "&" -> Bitwise.band(left, right)
      "|" -> Bitwise.bor(left, right)
      "^" -> Bitwise.bxor(left, right)
      "," -> right
      _ -> 0
    end
  end

  defp apply_unary_op(op, val) do
    case op do
      "-" -> -val
      "+" -> val
      "!" -> if val == 0, do: 1, else: 0
      "~" -> Bitwise.bnot(val)
      _ -> val
    end
  end

  defp apply_assignment_op(op, current, value) do
    case op do
      "=" -> value
      "+=" -> current + value
      "-=" -> current - value
      "*=" -> current * value
      "/=" -> if value != 0, do: div(current, value), else: 0
      "%=" -> if value != 0, do: rem(current, value), else: 0
      "<<=" -> Bitwise.bsl(current, value)
      ">>=" -> Bitwise.bsr(current, value)
      "&=" -> Bitwise.band(current, value)
      "|=" -> Bitwise.bor(current, value)
      "^=" -> Bitwise.bxor(current, value)
      _ -> value
    end
  end
end
