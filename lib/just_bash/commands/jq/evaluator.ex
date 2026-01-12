defmodule JustBash.Commands.Jq.Evaluator do
  @moduledoc """
  Evaluator for jq AST expressions.

  Takes a parsed jq AST and input data, returns the transformed output.
  """

  alias JustBash.Commands.Jq.Parser

  @doc """
  Evaluate a jq AST against input data.

  Returns `{:ok, results}` where results is a list of values,
  or `{:error, message}` on failure.
  """
  @spec evaluate(Parser.ast(), any(), map()) :: {:ok, [any()]} | {:error, String.t()}
  def evaluate(ast, data, opts) do
    try do
      results = eval(ast, data, opts)
      results = wrap_results(results)
      results = Enum.reject(results, &(&1 == :empty))
      {:ok, results}
    rescue
      e -> {:error, Exception.message(e)}
    catch
      {:eval_error, msg} -> {:error, msg}
    end
  end

  defp wrap_results({:multi, list}) when is_list(list), do: list
  defp wrap_results(other), do: [other]

  defp eval(:identity, data, _opts), do: data
  defp eval(:empty, _data, _opts), do: :empty

  defp eval({:literal, value}, _data, _opts), do: value

  defp eval({:field, name}, data, _opts) when is_map(data) do
    Map.get(data, name)
  end

  defp eval({:field, _name}, nil, _opts), do: nil

  defp eval({:field, name}, _data, _opts),
    do: throw({:eval_error, "cannot index non-object with #{name}"})

  defp eval({:index, n}, data, _opts) when is_list(data) do
    if n < 0 do
      Enum.at(data, n)
    else
      Enum.at(data, n)
    end
  end

  defp eval({:index, _n}, nil, _opts), do: nil

  defp eval({:index, n}, _data, _opts),
    do: throw({:eval_error, "cannot index non-array with #{n}"})

  defp eval({:slice, start_idx, end_idx}, data, _opts) when is_list(data) do
    len = length(data)
    start_idx = normalize_index(start_idx, len, 0)
    end_idx = normalize_index(end_idx, len, len)
    Enum.slice(data, start_idx..(end_idx - 1)//1)
  end

  defp eval({:slice, _start, _end}, nil, _opts), do: nil

  defp eval(:iterate, data, _opts) when is_list(data), do: {:multi, data}
  defp eval(:iterate, data, _opts) when is_map(data), do: {:multi, Map.values(data)}
  defp eval(:iterate, nil, _opts), do: {:multi, []}

  defp eval({:optional, expr}, data, opts) do
    try do
      eval(expr, data, opts)
    catch
      {:eval_error, _} -> nil
    end
  end

  defp eval({:pipe, left, right}, data, opts) do
    left_result = eval(left, data, opts)

    case left_result do
      {:multi, results} ->
        multi_results =
          Enum.flat_map(results, fn item ->
            case eval(right, item, opts) do
              {:multi, inner} -> inner
              other -> [other]
            end
          end)

        {:multi, multi_results}

      _ ->
        eval(right, left_result, opts)
    end
  end

  defp eval({:comma, exprs}, data, opts) do
    results =
      Enum.flat_map(exprs, fn expr ->
        case eval(expr, data, opts) do
          {:multi, inner} -> inner
          other -> [other]
        end
      end)

    {:multi, results}
  end

  defp eval({:array, [expr]}, data, opts) do
    result = eval(expr, data, opts)

    case result do
      {:multi, items} -> Enum.reject(items, &(&1 == :empty))
      :empty -> []
      other -> [other]
    end
  end

  defp eval({:array, []}, _data, _opts), do: []

  defp eval({:object, pairs}, data, opts) do
    Enum.reduce(pairs, %{}, fn {key_expr, val_expr}, acc ->
      key = eval(key_expr, data, opts)
      val = eval(val_expr, data, opts)
      Map.put(acc, to_string(key), val)
    end)
  end

  defp eval({:comparison, op, left, right}, data, opts) do
    left_val = eval(left, data, opts)
    right_val = eval(right, data, opts)
    compare(op, left_val, right_val)
  end

  defp eval({:boolean, :and, left, right}, data, opts) do
    left_val = eval(left, data, opts)
    if truthy?(left_val), do: eval(right, data, opts), else: left_val
  end

  defp eval({:boolean, :or, left, right}, data, opts) do
    left_val = eval(left, data, opts)
    if truthy?(left_val), do: left_val, else: eval(right, data, opts)
  end

  defp eval({:not, expr}, data, opts) do
    val = eval(expr, data, opts)
    not truthy?(val)
  end

  defp eval({:if, cond_expr, then_expr, else_expr}, data, opts) do
    cond_val = eval(cond_expr, data, opts)
    if truthy?(cond_val), do: eval(then_expr, data, opts), else: eval(else_expr, data, opts)
  end

  defp eval({:try, expr}, data, opts) do
    try do
      eval(expr, data, opts)
    catch
      {:eval_error, _} -> nil
    end
  end

  defp eval({:recursive_descent}, data, _opts), do: {:multi, recursive_descent(data)}

  defp eval({:arith, :add, left, right}, data, opts) do
    l = eval(left, data, opts)
    r = eval(right, data, opts)
    arith_add(l, r)
  end

  defp eval({:arith, :sub, left, right}, data, opts) do
    l = eval(left, data, opts)
    r = eval(right, data, opts)
    to_num(l) - to_num(r)
  end

  defp eval({:arith, :mul, left, right}, data, opts) do
    l = eval(left, data, opts)
    r = eval(right, data, opts)
    to_num(l) * to_num(r)
  end

  defp eval({:arith, :div, left, right}, data, opts) do
    l = eval(left, data, opts)
    r = eval(right, data, opts)
    to_num(l) / to_num(r)
  end

  defp eval({:arith, :mod, left, right}, data, opts) do
    l = eval(left, data, opts)
    r = eval(right, data, opts)
    rem(trunc(to_num(l)), trunc(to_num(r)))
  end

  defp eval({:func, name, args}, data, opts), do: eval_func(name, args, data, opts)

  defp eval(other, _data, _opts) do
    throw({:eval_error, "unsupported expression: #{inspect(other)}"})
  end

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

  defp eval_func(:keys, [], data, _opts) when is_map(data), do: Map.keys(data) |> Enum.sort()

  defp eval_func(:keys, [], data, _opts) when is_list(data),
    do: Enum.to_list(0..(length(data) - 1))

  defp eval_func(:values, [], data, _opts) when is_map(data), do: Map.values(data)
  defp eval_func(:values, [], data, _opts) when is_list(data), do: data

  defp eval_func(:length, [], data, _opts) when is_binary(data), do: String.length(data)
  defp eval_func(:length, [], data, _opts) when is_list(data), do: length(data)
  defp eval_func(:length, [], data, _opts) when is_map(data), do: map_size(data)
  defp eval_func(:length, [], nil, _opts), do: 0

  defp eval_func(:type, [], nil, _opts), do: "null"
  defp eval_func(:type, [], data, _opts) when is_boolean(data), do: "boolean"
  defp eval_func(:type, [], data, _opts) when is_number(data), do: "number"
  defp eval_func(:type, [], data, _opts) when is_binary(data), do: "string"
  defp eval_func(:type, [], data, _opts) when is_list(data), do: "array"
  defp eval_func(:type, [], data, _opts) when is_map(data), do: "object"

  defp eval_func(:has, [key_expr], data, opts) when is_map(data) do
    key = eval(key_expr, data, opts)
    Map.has_key?(data, key)
  end

  defp eval_func(:has, [key_expr], data, opts) when is_list(data) do
    key = eval(key_expr, data, opts)
    key >= 0 and key < length(data)
  end

  defp eval_func(:in, [container_expr], data, opts) do
    container = eval(container_expr, data, opts)

    cond do
      is_map(container) -> Map.has_key?(container, data)
      is_list(container) -> Enum.member?(container, data)
      true -> false
    end
  end

  defp eval_func(:map, [expr], data, opts) when is_list(data) do
    Enum.map(data, fn item -> eval(expr, item, opts) end)
  end

  defp eval_func(:select, [expr], data, opts) do
    val = eval(expr, data, opts)
    if truthy?(val), do: data, else: :empty
  end

  defp eval_func(:add, [], [], _opts), do: nil

  defp eval_func(:add, [], data, _opts) when is_list(data) do
    cond do
      Enum.all?(data, &is_number/1) -> Enum.sum(data)
      Enum.all?(data, &is_binary/1) -> Enum.join(data)
      Enum.all?(data, &is_list/1) -> List.flatten(data)
      Enum.all?(data, &is_map/1) -> Enum.reduce(data, %{}, &Map.merge(&2, &1))
      true -> throw({:eval_error, "cannot add mixed types"})
    end
  end

  defp eval_func(:first, [], data, _opts) when is_list(data), do: List.first(data)

  defp eval_func(:first, [expr], data, opts) do
    result = eval(expr, data, opts)

    case result do
      [h | _] -> h
      _ -> result
    end
  end

  defp eval_func(:last, [], data, _opts) when is_list(data), do: List.last(data)

  defp eval_func(:last, [expr], data, opts) do
    result = eval(expr, data, opts)

    case result do
      list when is_list(list) -> List.last(list)
      _ -> result
    end
  end

  defp eval_func(:nth, [n_expr], data, opts) when is_list(data) do
    n = eval(n_expr, data, opts)
    Enum.at(data, n)
  end

  defp eval_func(:flatten, [], data, _opts) when is_list(data), do: List.flatten(data)

  defp eval_func(:flatten, [depth_expr], data, opts) when is_list(data) do
    depth = eval(depth_expr, data, opts)
    flatten_to_depth(data, depth)
  end

  defp eval_func(:reverse, [], data, _opts) when is_list(data), do: Enum.reverse(data)
  defp eval_func(:reverse, [], data, _opts) when is_binary(data), do: String.reverse(data)

  defp eval_func(:sort, [], data, _opts) when is_list(data), do: Enum.sort(data)

  defp eval_func(:sort_by, [expr], data, opts) when is_list(data) do
    Enum.sort_by(data, fn item -> eval(expr, item, opts) end)
  end

  defp eval_func(:unique, [], data, _opts) when is_list(data), do: Enum.uniq(data)

  defp eval_func(:unique_by, [expr], data, opts) when is_list(data) do
    Enum.uniq_by(data, fn item -> eval(expr, item, opts) end)
  end

  defp eval_func(:group_by, [expr], data, opts) when is_list(data) do
    data
    |> Enum.group_by(fn item -> eval(expr, item, opts) end)
    |> Map.values()
  end

  defp eval_func(:min, [], data, _opts) when is_list(data) and data != [], do: Enum.min(data)
  defp eval_func(:min, [], [], _opts), do: nil

  defp eval_func(:max, [], data, _opts) when is_list(data) and data != [], do: Enum.max(data)
  defp eval_func(:max, [], [], _opts), do: nil

  defp eval_func(:min_by, [expr], data, opts) when is_list(data) and data != [] do
    Enum.min_by(data, fn item -> eval(expr, item, opts) end)
  end

  defp eval_func(:max_by, [expr], data, opts) when is_list(data) and data != [] do
    Enum.max_by(data, fn item -> eval(expr, item, opts) end)
  end

  defp eval_func(:contains, [other_expr], data, opts) do
    other = eval(other_expr, data, opts)
    json_contains?(data, other)
  end

  defp eval_func(:inside, [other_expr], data, opts) do
    other = eval(other_expr, data, opts)
    json_contains?(other, data)
  end

  defp eval_func(:split, [sep_expr], data, opts) when is_binary(data) do
    sep = eval(sep_expr, data, opts)
    String.split(data, sep)
  end

  defp eval_func(:join, [sep_expr], data, opts) when is_list(data) do
    sep = eval(sep_expr, data, opts)
    Enum.map_join(data, sep, &to_string/1)
  end

  defp eval_func(:ascii_downcase, [], data, _opts) when is_binary(data), do: String.downcase(data)
  defp eval_func(:ascii_upcase, [], data, _opts) when is_binary(data), do: String.upcase(data)

  defp eval_func(:ltrimstr, [prefix_expr], data, opts) when is_binary(data) do
    prefix = eval(prefix_expr, data, opts)
    if String.starts_with?(data, prefix), do: String.replace_prefix(data, prefix, ""), else: data
  end

  defp eval_func(:rtrimstr, [suffix_expr], data, opts) when is_binary(data) do
    suffix = eval(suffix_expr, data, opts)
    if String.ends_with?(data, suffix), do: String.replace_suffix(data, suffix, ""), else: data
  end

  defp eval_func(:startswith, [prefix_expr], data, opts) when is_binary(data) do
    prefix = eval(prefix_expr, data, opts)
    String.starts_with?(data, prefix)
  end

  defp eval_func(:endswith, [suffix_expr], data, opts) when is_binary(data) do
    suffix = eval(suffix_expr, data, opts)
    String.ends_with?(data, suffix)
  end

  defp eval_func(:tostring, [], data, _opts) do
    cond do
      is_binary(data) -> data
      is_nil(data) -> "null"
      true -> Jason.encode!(data)
    end
  end

  defp eval_func(:tonumber, [], data, _opts) when is_number(data), do: data

  defp eval_func(:tonumber, [], data, _opts) when is_binary(data) do
    case Float.parse(data) do
      {n, ""} -> if n == trunc(n), do: trunc(n), else: n
      _ -> throw({:eval_error, "cannot parse number: #{data}"})
    end
  end

  defp eval_func(:tojson, [], data, _opts), do: Jason.encode!(data)

  defp eval_func(:fromjson, [], data, _opts) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, result} -> result
      {:error, _} -> throw({:eval_error, "invalid JSON"})
    end
  end

  defp eval_func(:not, [], data, _opts), do: not truthy?(data)

  defp eval_func(:error, [msg_expr], data, opts) do
    msg = eval(msg_expr, data, opts)
    throw({:eval_error, to_string(msg)})
  end

  defp eval_func(:error, [], _data, _opts), do: throw({:eval_error, "error"})

  defp eval_func(:getpath, [path_expr], data, opts) do
    path = eval(path_expr, data, opts)
    get_path(data, path)
  end

  defp eval_func(:paths, [], data, _opts), do: get_all_paths(data, [])

  defp eval_func(:leaf_paths, [], data, _opts) do
    get_all_paths(data, [])
    |> Enum.filter(fn path ->
      val = get_path(data, path)
      not is_map(val) and not is_list(val)
    end)
  end

  defp eval_func(:env, [], _data, opts) do
    Map.get(opts, :env, %{})
  end

  defp eval_func(:now, [], _data, _opts) do
    DateTime.utc_now() |> DateTime.to_unix()
  end

  defp eval_func(:floor, [], data, _opts) when is_number(data), do: floor(data)
  defp eval_func(:ceil, [], data, _opts) when is_number(data), do: ceil(data)
  defp eval_func(:round, [], data, _opts) when is_number(data), do: round(data)
  defp eval_func(:fabs, [], data, _opts) when is_number(data), do: abs(data)
  defp eval_func(:sqrt, [], data, _opts) when is_number(data), do: :math.sqrt(data)

  defp eval_func(name, _args, _data, _opts) do
    throw({:eval_error, "unknown function: #{name}"})
  end

  defp compare(:eq, a, b), do: a == b
  defp compare(:neq, a, b), do: a != b
  defp compare(:lt, a, b), do: a < b
  defp compare(:gt, a, b), do: a > b
  defp compare(:lte, a, b), do: a <= b
  defp compare(:gte, a, b), do: a >= b

  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true

  defp normalize_index(nil, _len, default), do: default
  defp normalize_index(n, len, _default) when n < 0, do: max(0, len + n)
  defp normalize_index(n, _len, _default), do: n

  defp flatten_to_depth(list, 0), do: list

  defp flatten_to_depth(list, depth) when depth > 0 do
    Enum.flat_map(list, fn
      item when is_list(item) -> flatten_to_depth(item, depth - 1)
      item -> [item]
    end)
  end

  defp json_contains?(a, b) when is_map(a) and is_map(b) do
    Enum.all?(b, fn {k, v} ->
      Map.has_key?(a, k) and json_contains?(Map.get(a, k), v)
    end)
  end

  defp json_contains?(a, b) when is_list(a) and is_list(b) do
    Enum.all?(b, fn b_item ->
      Enum.any?(a, fn a_item -> json_contains?(a_item, b_item) end)
    end)
  end

  defp json_contains?(a, b) when is_binary(a) and is_binary(b) do
    String.contains?(a, b)
  end

  defp json_contains?(a, b), do: a == b

  defp recursive_descent(data) when is_map(data) do
    values = Map.values(data)
    [data | Enum.flat_map(values, &recursive_descent/1)]
  end

  defp recursive_descent(data) when is_list(data) do
    [data | Enum.flat_map(data, &recursive_descent/1)]
  end

  defp recursive_descent(data), do: [data]

  defp get_path(data, []), do: data

  defp get_path(data, [key | rest]) when is_map(data) and is_binary(key) do
    get_path(Map.get(data, key), rest)
  end

  defp get_path(data, [idx | rest]) when is_list(data) and is_integer(idx) do
    get_path(Enum.at(data, idx), rest)
  end

  defp get_path(_, _), do: nil

  defp get_all_paths(data, prefix) when is_map(data) do
    Enum.flat_map(data, fn {k, v} ->
      path = prefix ++ [k]
      [path | get_all_paths(v, path)]
    end)
  end

  defp get_all_paths(data, prefix) when is_list(data) do
    data
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, i} ->
      path = prefix ++ [i]
      [path | get_all_paths(v, path)]
    end)
  end

  defp get_all_paths(_, _), do: []
end
