defmodule JustBash.Arithmetic.Evaluator do
  @moduledoc """
  Evaluates arithmetic expression AST nodes.

  Takes parsed AST nodes and an environment (variable bindings),
  returns the computed integer value and updated environment.

  Handles:
  - Arithmetic operations: +, -, *, /, %, **
  - Comparison operations: <, <=, >, >=, ==, !=
  - Bitwise operations: &, |, ^, ~, <<, >>
  - Logical operations: &&, ||, !
  - Assignment operations: =, +=, -=, etc.
  - Pre/post increment/decrement: ++, --
  - Ternary conditional: ? :
  """

  alias JustBash.AST

  @doc """
  Evaluate an arithmetic AST in the given environment.
  Returns {:ok, result, updated_env} or {:error, reason, env}.
  """
  @spec evaluate(AST.arith_expr(), map()) ::
          {:ok, integer(), map()} | {:error, :division_by_zero, map()}
  def evaluate(ast, env) do
    case eval_expr(ast, env) do
      {:ok, result, env} -> {:ok, result, env}
      {:error, reason, env} -> {:error, reason, env}
    end
  end

  # Number literal
  defp eval_expr(%AST.ArithNumber{value: value}, env) do
    {:ok, value, env}
  end

  # Variable reference
  defp eval_expr(%AST.ArithVariable{name: name}, env) do
    value = resolve_variable(env, name)
    {:ok, value, env}
  end

  # Parenthesized group
  defp eval_expr(%AST.ArithGroup{expression: expr}, env) do
    eval_expr(expr, env)
  end

  # Binary operations
  defp eval_expr(%AST.ArithBinary{operator: op, left: left, right: right}, env) do
    case op do
      "||" ->
        case eval_expr(left, env) do
          {:ok, left_val, env} ->
            if left_val != 0, do: {:ok, 1, env}, else: do_logical_or(right, env)

          {:error, _, _} = error ->
            error
        end

      "&&" ->
        case eval_expr(left, env) do
          {:ok, left_val, env} ->
            if left_val == 0, do: {:ok, 0, env}, else: do_logical_and(right, env)

          {:error, _, _} = error ->
            error
        end

      _ ->
        with {:ok, left_val, env} <- eval_expr(left, env),
             {:ok, right_val, env} <- eval_expr(right, env),
             {:ok, result} <- apply_binary_op(op, left_val, right_val) do
          {:ok, result, env}
        else
          {:error, reason} -> {:error, reason, env}
          {:error, reason, env} -> {:error, reason, env}
        end
    end
  end

  # Unary operations
  defp eval_expr(%AST.ArithUnary{operator: op, operand: operand, prefix: prefix}, env) do
    case op do
      "++" ->
        do_increment(operand, env, prefix, 1)

      "--" ->
        do_increment(operand, env, prefix, -1)

      _ ->
        case eval_expr(operand, env) do
          {:ok, val, env} -> {:ok, apply_unary_op(op, val), env}
          {:error, _, _} = error -> error
        end
    end
  end

  # Ternary conditional
  defp eval_expr(%AST.ArithTernary{condition: cond, consequent: cons, alternate: alt}, env) do
    case eval_expr(cond, env) do
      {:ok, cond_val, env} ->
        if cond_val != 0 do
          eval_expr(cons, env)
        else
          eval_expr(alt, env)
        end

      {:error, _, _} = error ->
        error
    end
  end

  # Assignment
  defp eval_expr(%AST.ArithAssignment{operator: op, variable: var, value: value}, env) do
    case eval_expr(value, env) do
      {:ok, val, env} ->
        current = resolve_variable(env, var)

        case apply_assignment_op(op, current, val) do
          {:ok, new_val} ->
            env = Map.put(env, var, to_string(new_val))
            {:ok, new_val, env}

          {:error, reason} ->
            {:error, reason, env}
        end

      {:error, _, _} = error ->
        error
    end
  end

  # Arithmetic expansion wrapper
  defp eval_expr(%AST.ArithmeticExpansion{expression: expr}, env) do
    eval_expr(expr, env)
  end

  # Fallback
  defp eval_expr(_, env), do: {:ok, 0, env}

  # Logical OR short-circuit
  defp do_logical_or(right, env) do
    case eval_expr(right, env) do
      {:ok, right_val, env} -> {:ok, if(right_val != 0, do: 1, else: 0), env}
      {:error, _, _} = error -> error
    end
  end

  # Logical AND short-circuit
  defp do_logical_and(right, env) do
    case eval_expr(right, env) do
      {:ok, right_val, env} -> {:ok, if(right_val != 0, do: 1, else: 0), env}
      {:error, _, _} = error -> error
    end
  end

  # Increment/decrement for variables
  defp do_increment(%AST.ArithVariable{name: name}, env, prefix, delta) do
    current = resolve_variable(env, name)
    new_val = current + delta
    env = Map.put(env, name, to_string(new_val))

    if prefix do
      {:ok, new_val, env}
    else
      {:ok, current, env}
    end
  end

  defp do_increment(operand, env, _prefix, _delta) do
    eval_expr(operand, env)
  end

  # Variable resolution
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

  # Binary operation dispatch
  defp apply_binary_op(op, left, right) when op in ["+", "-", "*", "/", "%", "**"] do
    apply_arithmetic_op(op, left, right)
  end

  defp apply_binary_op(op, left, right) when op in ["<", "<=", ">", ">=", "==", "!="] do
    {:ok, apply_comparison_op(op, left, right)}
  end

  defp apply_binary_op(op, left, right) when op in ["&", "|", "^", "<<", ">>"] do
    {:ok, apply_bitwise_op(op, left, right)}
  end

  defp apply_binary_op(",", _left, right), do: {:ok, right}
  defp apply_binary_op(_op, _left, _right), do: {:ok, 0}

  # Arithmetic operations
  defp apply_arithmetic_op("+", left, right), do: {:ok, left + right}
  defp apply_arithmetic_op("-", left, right), do: {:ok, left - right}
  defp apply_arithmetic_op("*", left, right), do: {:ok, left * right}
  defp apply_arithmetic_op("/", _left, 0), do: {:error, :division_by_zero}
  defp apply_arithmetic_op("/", left, right), do: {:ok, div(left, right)}
  defp apply_arithmetic_op("%", _left, 0), do: {:error, :division_by_zero}
  defp apply_arithmetic_op("%", left, right), do: {:ok, rem(left, right)}
  defp apply_arithmetic_op("**", _left, right) when right < 0, do: {:ok, 0}
  defp apply_arithmetic_op("**", left, right), do: {:ok, trunc(:math.pow(left, right))}

  # Comparison operations
  defp apply_comparison_op("<", left, right), do: bool_to_int(left < right)
  defp apply_comparison_op("<=", left, right), do: bool_to_int(left <= right)
  defp apply_comparison_op(">", left, right), do: bool_to_int(left > right)
  defp apply_comparison_op(">=", left, right), do: bool_to_int(left >= right)
  defp apply_comparison_op("==", left, right), do: bool_to_int(left == right)
  defp apply_comparison_op("!=", left, right), do: bool_to_int(left != right)

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  # Bitwise operations
  defp apply_bitwise_op("&", left, right), do: Bitwise.band(left, right)
  defp apply_bitwise_op("|", left, right), do: Bitwise.bor(left, right)
  defp apply_bitwise_op("^", left, right), do: Bitwise.bxor(left, right)
  defp apply_bitwise_op("<<", left, right), do: Bitwise.bsl(left, right)
  defp apply_bitwise_op(">>", left, right), do: Bitwise.bsr(left, right)

  # Unary operations
  defp apply_unary_op("-", val), do: -val
  defp apply_unary_op("+", val), do: val
  defp apply_unary_op("!", val), do: if(val == 0, do: 1, else: 0)
  defp apply_unary_op("~", val), do: Bitwise.bnot(val)
  defp apply_unary_op(_, val), do: val

  # Assignment operations
  defp apply_assignment_op("=", _current, value), do: {:ok, value}
  defp apply_assignment_op("+=", current, value), do: {:ok, current + value}
  defp apply_assignment_op("-=", current, value), do: {:ok, current - value}
  defp apply_assignment_op("*=", current, value), do: {:ok, current * value}
  defp apply_assignment_op("/=", _current, 0), do: {:error, :division_by_zero}
  defp apply_assignment_op("/=", current, value), do: {:ok, div(current, value)}
  defp apply_assignment_op("%=", _current, 0), do: {:error, :division_by_zero}
  defp apply_assignment_op("%=", current, value), do: {:ok, rem(current, value)}
  defp apply_assignment_op("<<=", current, value), do: {:ok, Bitwise.bsl(current, value)}
  defp apply_assignment_op(">>=", current, value), do: {:ok, Bitwise.bsr(current, value)}
  defp apply_assignment_op("&=", current, value), do: {:ok, Bitwise.band(current, value)}
  defp apply_assignment_op("|=", current, value), do: {:ok, Bitwise.bor(current, value)}
  defp apply_assignment_op("^=", current, value), do: {:ok, Bitwise.bxor(current, value)}
  defp apply_assignment_op(_op, _current, value), do: {:ok, value}
end
