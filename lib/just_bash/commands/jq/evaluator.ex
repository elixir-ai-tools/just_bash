defmodule JustBash.Commands.Jq.Evaluator do
  @moduledoc """
  Evaluator for jq AST expressions.

  Takes a parsed jq AST and input data, returns the transformed output.
  Complex functionality is delegated to submodules:

  - `Evaluator.Functions` - Built-in function implementations
  - `Evaluator.Format` - Output formatting (@csv, @json, etc.)
  """

  alias JustBash.Commands.Jq.Evaluator.Format
  alias JustBash.Commands.Jq.Evaluator.Functions
  alias JustBash.Commands.Jq.Parser

  @doc """
  Evaluate a jq AST against input data.

  Returns `{:ok, results}` where results is a list of values,
  or `{:error, message}` on failure.
  """
  @spec evaluate(Parser.ast(), any(), map()) :: {:ok, [any()]} | {:error, String.t()}
  def evaluate(ast, data, opts) do
    results = eval(ast, data, opts)
    results = wrap_results(results)
    results = Enum.reject(results, &(&1 == :empty))
    {:ok, results}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    {:eval_error, msg} -> {:error, msg}
  end

  # Public interface for submodules to call back
  @doc false
  def eval(ast, data, opts), do: do_eval(ast, data, opts)

  @doc false
  def eval_to_list(expr, data, opts) do
    case do_eval(expr, data, opts) do
      {:multi, items} -> items
      item -> [item]
    end
  end

  # Result wrapping
  defp wrap_results({:multi, list}) when is_list(list), do: list
  defp wrap_results(other), do: [other]

  # Core evaluation - primitives
  defp do_eval(:identity, data, _opts), do: data
  defp do_eval(:empty, _data, _opts), do: :empty
  defp do_eval({:literal, value}, _data, _opts), do: value

  defp do_eval({:var, name}, _data, opts) do
    bindings = Map.get(opts, :bindings, %{})
    Map.get(bindings, name) || throw({:eval_error, "variable $#{name} not defined"})
  end

  defp do_eval({:string_interp, parts}, data, opts) do
    Enum.map_join(parts, fn
      {:str, s} -> s
      {:interp, expr} -> Format.stringify(do_eval(expr, data, opts))
    end)
  end

  # Field and index access
  defp do_eval({:field, name}, data, _opts) when is_map(data), do: Map.get(data, name)
  defp do_eval({:field, _name}, nil, _opts), do: nil

  defp do_eval({:field, name}, _data, _opts) do
    throw({:eval_error, "cannot index non-object with #{name}"})
  end

  defp do_eval({:index, n}, data, _opts) when is_list(data), do: Enum.at(data, n)
  defp do_eval({:index, _n}, nil, _opts), do: nil

  defp do_eval({:index, n}, _data, _opts) do
    throw({:eval_error, "cannot index non-array with #{n}"})
  end

  defp do_eval({:slice, start_idx, end_idx}, data, _opts) when is_list(data) do
    len = length(data)
    start_idx = normalize_index(start_idx, len, 0)
    end_idx = normalize_index(end_idx, len, len)
    Enum.slice(data, start_idx..(end_idx - 1)//1)
  end

  defp do_eval({:slice, _start, _end}, nil, _opts), do: nil

  # Iteration
  defp do_eval(:iterate, data, _opts) when is_list(data), do: {:multi, data}
  defp do_eval(:iterate, data, _opts) when is_map(data), do: {:multi, Map.values(data)}
  defp do_eval(:iterate, nil, _opts), do: {:multi, []}

  defp do_eval({:optional, expr}, data, opts) do
    eval_optional(expr, data, opts)
  end

  # Pipe and comma
  defp do_eval({:pipe, left, right}, data, opts) do
    left_result = do_eval(left, data, opts)
    eval_pipe_right(left_result, right, opts)
  end

  defp do_eval({:comma, exprs}, data, opts) do
    results =
      Enum.flat_map(exprs, fn expr ->
        case do_eval(expr, data, opts) do
          {:multi, inner} -> inner
          other -> [other]
        end
      end)

    {:multi, results}
  end

  # Array and object construction
  defp do_eval({:array, [expr]}, data, opts) do
    result = do_eval(expr, data, opts)
    array_from_result(result)
  end

  defp do_eval({:array, []}, _data, _opts), do: []

  defp do_eval({:object, pairs}, data, opts) do
    Enum.reduce(pairs, %{}, fn {key_expr, val_expr}, acc ->
      key = do_eval(key_expr, data, opts)
      val = do_eval(val_expr, data, opts)
      Map.put(acc, to_string(key), val)
    end)
  end

  # Comparison and boolean operators
  defp do_eval({:comparison, op, left, right}, data, opts) do
    left_val = do_eval(left, data, opts)
    right_val = do_eval(right, data, opts)
    compare(op, left_val, right_val)
  end

  defp do_eval({:boolean, :and, left, right}, data, opts) do
    left_val = do_eval(left, data, opts)
    if truthy?(left_val), do: do_eval(right, data, opts), else: left_val
  end

  defp do_eval({:boolean, :or, left, right}, data, opts) do
    left_val = do_eval(left, data, opts)
    if truthy?(left_val), do: left_val, else: do_eval(right, data, opts)
  end

  defp do_eval({:alternative, left, right}, data, opts) do
    eval_alternative(left, right, data, opts)
  end

  defp do_eval({:not, expr}, data, opts) do
    val = do_eval(expr, data, opts)
    not truthy?(val)
  end

  # Control flow
  defp do_eval({:if, cond_expr, then_expr, else_expr}, data, opts) do
    cond_val = do_eval(cond_expr, data, opts)
    if truthy?(cond_val), do: do_eval(then_expr, data, opts), else: do_eval(else_expr, data, opts)
  end

  defp do_eval({:try, expr}, data, opts) do
    eval_try(expr, data, opts)
  end

  # Reduce and foreach
  defp do_eval({:reduce, expr, var_name, init, update}, data, opts) do
    items = eval_to_list(expr, data, opts)
    init_val = do_eval(init, data, opts)

    Enum.reduce(items, init_val, fn item, acc ->
      bindings = Map.get(opts, :bindings, %{})
      new_bindings = Map.put(bindings, var_name, item)
      new_opts = Map.put(opts, :bindings, new_bindings)
      do_eval(update, acc, new_opts)
    end)
  end

  defp do_eval({:foreach, expr, var_name, init, update, extract}, data, opts) do
    items = eval_to_list(expr, data, opts)
    init_val = do_eval(init, data, opts)

    {results, _} =
      Enum.map_reduce(items, init_val, fn item, acc ->
        bindings = Map.get(opts, :bindings, %{})
        new_bindings = Map.put(bindings, var_name, item)
        new_opts = Map.put(opts, :bindings, new_bindings)
        new_acc = do_eval(update, acc, new_opts)
        extracted = do_eval(extract, new_acc, new_opts)
        {extracted, new_acc}
      end)

    {:multi, results}
  end

  defp do_eval({:recursive_descent}, data, _opts), do: {:multi, recursive_descent(data)}

  # Arithmetic operators
  defp do_eval({:arith, :add, left, right}, data, opts) do
    l = do_eval(left, data, opts)
    r = do_eval(right, data, opts)
    arith_add(l, r)
  end

  defp do_eval({:arith, :sub, left, right}, data, opts) do
    l = do_eval(left, data, opts)
    r = do_eval(right, data, opts)
    to_num(l) - to_num(r)
  end

  defp do_eval({:arith, :mul, left, right}, data, opts) do
    l = do_eval(left, data, opts)
    r = do_eval(right, data, opts)
    to_num(l) * to_num(r)
  end

  defp do_eval({:arith, :div, left, right}, data, opts) do
    l = do_eval(left, data, opts)
    r = do_eval(right, data, opts)
    to_num(l) / to_num(r)
  end

  defp do_eval({:arith, :mod, left, right}, data, opts) do
    l = do_eval(left, data, opts)
    r = do_eval(right, data, opts)
    rem(trunc(to_num(l)), trunc(to_num(r)))
  end

  # Function calls - delegate to Functions module
  defp do_eval({:func, name, args}, data, opts) do
    Functions.eval_func(name, args, data, opts, __MODULE__)
  end

  # Format strings - delegate to Format module
  defp do_eval({:format, format_type}, data, _opts) do
    Format.format(format_type, data)
  end

  # Catch-all for unsupported expressions
  defp do_eval(other, _data, _opts) do
    throw({:eval_error, "unsupported expression: #{inspect(other)}"})
  end

  # Pipe helper - handles multi-value results
  defp eval_pipe_right({:multi, results}, right, opts) do
    multi_results =
      Enum.flat_map(results, fn item ->
        case do_eval(right, item, opts) do
          {:multi, inner} -> inner
          other -> [other]
        end
      end)

    {:multi, multi_results}
  end

  defp eval_pipe_right(left_result, right, opts) do
    do_eval(right, left_result, opts)
  end

  # Array construction helper
  defp array_from_result({:multi, items}), do: Enum.reject(items, &(&1 == :empty))
  defp array_from_result(:empty), do: []
  defp array_from_result(other), do: [other]

  # Arithmetic helpers
  defp arith_add(l, r) when is_number(l) and is_number(r), do: l + r
  defp arith_add(l, r) when is_binary(l) and is_binary(r), do: l <> r
  defp arith_add(l, r) when is_list(l) and is_list(r), do: l ++ r
  defp arith_add(l, r) when is_map(l) and is_map(r), do: Map.merge(l, r)
  defp arith_add(nil, r), do: r
  defp arith_add(l, nil), do: l

  defp to_num(n) when is_number(n), do: n

  defp to_num(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_num(_), do: 0

  # Comparison helpers
  defp compare(:eq, a, b), do: a == b
  defp compare(:neq, a, b), do: a != b
  defp compare(:lt, a, b), do: a < b
  defp compare(:gt, a, b), do: a > b
  defp compare(:lte, a, b), do: a <= b
  defp compare(:gte, a, b), do: a >= b

  # Boolean helper
  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true

  # Index normalization
  defp normalize_index(nil, _len, default), do: default
  defp normalize_index(n, len, _default) when n < 0, do: max(0, len + n)
  defp normalize_index(n, _len, _default), do: n

  # Recursive descent helper
  defp recursive_descent(data) when is_map(data) do
    values = Map.values(data)
    [data | Enum.flat_map(values, &recursive_descent/1)]
  end

  defp recursive_descent(data) when is_list(data) do
    [data | Enum.flat_map(data, &recursive_descent/1)]
  end

  defp recursive_descent(data), do: [data]

  # Error-handling helpers with implicit catch (to satisfy Credo)
  defp eval_optional(expr, data, opts) do
    do_eval(expr, data, opts)
  catch
    {:eval_error, _} -> nil
  end

  defp eval_alternative(left, right, data, opts) do
    left_val = do_eval(left, data, opts)
    if left_val == nil or left_val == false, do: do_eval(right, data, opts), else: left_val
  catch
    {:eval_error, _} -> do_eval(right, data, opts)
  end

  defp eval_try(expr, data, opts) do
    do_eval(expr, data, opts)
  catch
    {:eval_error, _} -> nil
  end
end
