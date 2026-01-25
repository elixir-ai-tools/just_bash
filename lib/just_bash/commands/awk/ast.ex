defmodule JustBash.Commands.Awk.AST do
  @moduledoc """
  AST node constructors for AWK programs.

  Produces AST in the format expected by the evaluator.
  """

  # ─── Program Structure ────────────────────────────────────────────
  # Evaluator expects: %{begin_blocks: [[stmt]], end_blocks: [[stmt]], main_rules: [{pattern, [stmt]}]}

  @doc """
  Build a program from a list of rules and functions.
  Transforms the rule-based structure into begin_blocks/end_blocks/main_rules.
  """
  def program(rules, _functions \\ []) do
    {begin_blocks, end_blocks, main_rules} =
      Enum.reduce(rules, {[], [], []}, fn rule, {begins, ends, mains} ->
        case rule do
          %{pattern: :begin, action: action} ->
            {[unwrap_statements(action) | begins], ends, mains}

          %{pattern: :end, action: action} ->
            {begins, [unwrap_statements(action) | ends], mains}

          %{pattern: pattern, action: action} ->
            rule_tuple = {normalize_pattern(pattern), unwrap_statements(action)}
            {begins, ends, [rule_tuple | mains]}
        end
      end)

    %{
      begin_blocks: Enum.reverse(begin_blocks),
      end_blocks: Enum.reverse(end_blocks),
      main_rules: Enum.reverse(main_rules)
    }
  end

  defp unwrap_statements(%{statements: stmts}), do: stmts
  defp unwrap_statements(stmts) when is_list(stmts), do: stmts
  defp unwrap_statements(stmt), do: [stmt]

  defp normalize_pattern(nil), do: nil
  defp normalize_pattern({:regex, pattern}), do: {:regex, pattern}
  defp normalize_pattern({:expr, expr}), do: {:condition, expr}

  defp normalize_pattern({:range, start_p, end_p}),
    do: {:range, normalize_pattern(start_p), normalize_pattern(end_p)}

  defp normalize_pattern(other), do: other

  def rule(pattern, action) do
    %{pattern: pattern, action: action}
  end

  def block(statements) do
    %{statements: statements}
  end

  # ─── Expressions ───────────────────────────────────────────────

  def number(n) when is_binary(n) do
    case Float.parse(n) do
      {f, ""} -> {:number, f}
      _ -> {:number, 0.0}
    end
  end

  def number(n) when is_number(n), do: {:number, n / 1}

  def string(s), do: {:literal, s}
  def regex(pattern), do: {:regex, pattern}
  def variable(name), do: {:variable, name}

  def field({:number, n}) when is_number(n), do: {:field, round(n)}
  def field({:variable, name}), do: {:field_var, name}
  def field(index), do: {:field_expr, index}

  def array_access(array, key), do: {:array_access, array, key}

  # Binary operations - evaluator expects {:op, left, right}
  def binary(:add, left, right), do: {:add, left, right}
  def binary(:sub, left, right), do: {:sub, left, right}
  def binary(:mul, left, right), do: {:mul, left, right}
  def binary(:div, left, right), do: {:div, left, right}
  def binary(:mod, left, right), do: {:mod, left, right}
  def binary(:pow, left, right), do: {:pow, left, right}
  def binary(:eq, left, right), do: {:==, left, right}
  def binary(:ne, left, right), do: {:!=, left, right}
  def binary(:lt, left, right), do: {:<, left, right}
  def binary(:gt, left, right), do: {:>, left, right}
  def binary(:le, left, right), do: {:<=, left, right}
  def binary(:ge, left, right), do: {:>=, left, right}
  def binary(:match, left, right), do: {:match, left, right}
  def binary(:not_match, left, right), do: {:not_match, left, right}
  def binary(:and, left, right), do: {:and, left, right}
  def binary(:or, left, right), do: {:or, left, right}
  def binary(:concat, left, right), do: {:concat, left, right}

  # Unary operations
  def unary(:not, operand), do: {:not, operand}
  def unary(:negate, operand), do: {:negate, operand}
  def unary(:plus, operand), do: operand

  def ternary(cond_expr, consequent, alternate), do: {:ternary, cond_expr, consequent, alternate}

  # Assignment - evaluator expects {:assign, var_name_string, value}
  def assign(:assign, {:variable, name}, value), do: {:assign, name, value}
  def assign(:assign, {:array_access, array, key}, value), do: {:array_assign, array, key, value}
  def assign(:assign, {:field_expr, index}, value), do: {:field_assign, index, value}
  def assign(:assign, {:field, n}, value), do: {:field_assign, {:number, n}, value}

  def assign(:add_assign, {:variable, name}, value), do: {:add_assign, name, value}

  def assign(:add_assign, {:array_access, array, key}, value),
    do: {:array_add_assign, array, key, value}

  def assign(:sub_assign, {:variable, name}, value), do: {:sub_assign, name, value}
  def assign(:mul_assign, {:variable, name}, value), do: {:mul_assign, name, value}
  def assign(:div_assign, {:variable, name}, value), do: {:div_assign, name, value}
  def assign(:mod_assign, {:variable, name}, value), do: {:mod_assign, name, value}
  def assign(:pow_assign, {:variable, name}, value), do: {:pow_assign, name, value}

  # Increment/decrement - evaluator expects {:increment, var_name_string}
  def pre_inc({:variable, name}), do: {:pre_increment, name}
  def pre_inc({:array_access, array, key}), do: {:array_pre_increment, array, key}

  def post_inc({:variable, name}), do: {:increment, name}
  def post_inc({:array_access, array, key}), do: {:array_increment, array, key}

  def pre_dec({:variable, name}), do: {:pre_decrement, name}
  def pre_dec({:array_access, array, key}), do: {:array_pre_decrement, array, key}

  def post_dec({:variable, name}), do: {:decrement, name}
  def post_dec({:array_access, array, key}), do: {:array_decrement, array, key}

  def call(name, args), do: {:call, name, args}
  def in_expr(key, array), do: {:in, key, array}

  # ─── Statements ───────────────────────────────────────────────

  # Print - evaluator expects {:print, {:concat, args}} or {:print, {:comma_sep, args}}
  # Since parser always comma-separates args, use :comma_sep
  def print(args, nil), do: {:print, {:comma_sep, args}}
  def print(args, {:redirect, :gt, file}), do: {:print_redirect, {:comma_sep, args}, file}
  def print(args, {:redirect, :append, file}), do: {:print_append, {:comma_sep, args}, file}

  def printf(format, args, nil), do: {:printf, {unwrap_string(format), args}}

  def printf(format, args, {:redirect, :gt, file}),
    do: {:printf_redirect, {unwrap_string(format), args}, file}

  def printf(format, args, {:redirect, :append, file}),
    do: {:printf_append, {unwrap_string(format), args}, file}

  defp unwrap_string({:literal, s}), do: s
  defp unwrap_string({:string, s}), do: s
  defp unwrap_string(s) when is_binary(s), do: s
  defp unwrap_string(other), do: other

  def if_stmt(cond_expr, consequent, nil), do: {:if, cond_expr, consequent, nil}
  def if_stmt(cond_expr, consequent, alternate), do: {:if, cond_expr, consequent, alternate}

  def while_stmt(cond_expr, body), do: {:while, cond_expr, unwrap_statements(body)}
  def do_while(body, cond_expr), do: {:do_while, unwrap_statements(body), cond_expr}

  def for_stmt(init, cond_expr, update, body) do
    {:for, init, cond_expr, update, unwrap_statements(body)}
  end

  def for_in(var, array, body), do: {:for_in, var, array, unwrap_statements(body)}

  def exit_stmt(nil), do: {:exit, 0}
  def exit_stmt(code), do: {:exit, code}

  def return_stmt(value), do: {:return, value}

  def delete({:array_access, array, key}), do: {:delete_element, array, key}
  def delete({:variable, array}), do: {:delete_array, array}

  # Expression statement - just return the expression itself
  # The evaluator will handle it in execute_statement
  def expr_stmt(expr), do: expr
end
