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

  defp eval_to_list(expr, data, opts) do
    case eval(expr, data, opts) do
      {:multi, items} -> items
      item -> [item]
    end
  end

  defp eval(:identity, data, _opts), do: data
  defp eval(:empty, _data, _opts), do: :empty

  defp eval({:literal, value}, _data, _opts), do: value

  defp eval({:var, name}, _data, opts) do
    bindings = Map.get(opts, :bindings, %{})
    Map.get(bindings, name) || throw({:eval_error, "variable $#{name} not defined"})
  end

  defp eval({:string_interp, parts}, data, opts) do
    Enum.map_join(parts, fn
      {:str, s} -> s
      {:interp, expr} -> stringify(eval(expr, data, opts))
    end)
  end

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
    eval_pipe_right(left_result, right, opts)
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
    array_from_result(result)
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

  defp eval({:alternative, left, right}, data, opts) do
    try do
      left_val = eval(left, data, opts)
      if left_val == nil or left_val == false, do: eval(right, data, opts), else: left_val
    catch
      {:eval_error, _} -> eval(right, data, opts)
    end
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

  # reduce EXPR as $VAR (INIT; UPDATE)
  defp eval({:reduce, expr, var_name, init, update}, data, opts) do
    items = eval_to_list(expr, data, opts)
    init_val = eval(init, data, opts)

    Enum.reduce(items, init_val, fn item, acc ->
      bindings = Map.get(opts, :bindings, %{})
      new_bindings = Map.put(bindings, var_name, item)
      new_opts = Map.put(opts, :bindings, new_bindings)
      eval(update, acc, new_opts)
    end)
  end

  # foreach EXPR as $VAR (INIT; UPDATE; EXTRACT) or (INIT; UPDATE)
  defp eval({:foreach, expr, var_name, init, update, extract}, data, opts) do
    items = eval_to_list(expr, data, opts)
    init_val = eval(init, data, opts)

    {results, _} =
      Enum.map_reduce(items, init_val, fn item, acc ->
        bindings = Map.get(opts, :bindings, %{})
        new_bindings = Map.put(bindings, var_name, item)
        new_opts = Map.put(opts, :bindings, new_bindings)
        new_acc = eval(update, acc, new_opts)
        extracted = eval(extract, new_acc, new_opts)
        {extracted, new_acc}
      end)

    {:multi, results}
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

  defp eval({:format, :csv}, data, _opts) when is_list(data) do
    Enum.map_join(data, ",", &format_csv_field/1)
  end

  defp eval({:format, :tsv}, data, _opts) when is_list(data) do
    Enum.map_join(data, "\t", &format_tsv_field/1)
  end

  defp eval({:format, :json}, data, _opts), do: Jason.encode!(data)

  defp eval({:format, :text}, data, _opts) when is_binary(data), do: data
  defp eval({:format, :text}, data, _opts), do: to_string(data)

  defp eval({:format, :base64}, data, _opts) when is_binary(data), do: Base.encode64(data)

  defp eval({:format, :base64d}, data, _opts) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, decoded} -> decoded
      :error -> throw({:eval_error, "invalid base64"})
    end
  end

  defp eval({:format, :uri}, data, _opts) when is_binary(data), do: URI.encode(data)

  defp eval({:format, :html}, data, _opts) when is_binary(data) do
    data
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp eval({:format, name}, _data, _opts) do
    throw({:eval_error, "unknown format: @#{name}"})
  end

  defp eval(other, _data, _opts) do
    throw({:eval_error, "unsupported expression: #{inspect(other)}"})
  end

  defp eval_pipe_right({:multi, results}, right, opts) do
    multi_results =
      Enum.flat_map(results, fn item ->
        case eval(right, item, opts) do
          {:multi, inner} -> inner
          other -> [other]
        end
      end)

    {:multi, multi_results}
  end

  defp eval_pipe_right(left_result, right, opts) do
    eval(right, left_result, opts)
  end

  defp array_from_result({:multi, items}), do: Enum.reject(items, &(&1 == :empty))
  defp array_from_result(:empty), do: []
  defp array_from_result(other), do: [other]

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

  # to_entries: {a:1,b:2} -> [{key:"a",value:1},{key:"b",value:2}]
  defp eval_func(:to_entries, [], data, _opts) when is_map(data) do
    Enum.map(data, fn {k, v} -> %{"key" => k, "value" => v} end)
  end

  # from_entries: [{key:"a",value:1}] -> {a:1}
  defp eval_func(:from_entries, [], data, _opts) when is_list(data) do
    Enum.reduce(data, %{}, fn entry, acc ->
      key = Map.get(entry, "key") || Map.get(entry, "k") || Map.get(entry, "name")
      value = Map.get(entry, "value") || Map.get(entry, "v")
      if key, do: Map.put(acc, to_string(key), value), else: acc
    end)
  end

  # with_entries(f): to_entries | map(f) | from_entries
  defp eval_func(:with_entries, [expr], data, opts) when is_map(data) do
    entries = Enum.map(data, fn {k, v} -> %{"key" => k, "value" => v} end)
    transformed = Enum.map(entries, fn entry -> eval(expr, entry, opts) end)

    Enum.reduce(transformed, %{}, fn entry, acc ->
      key = Map.get(entry, "key") || Map.get(entry, "k") || Map.get(entry, "name")
      value = Map.get(entry, "value") || Map.get(entry, "v")
      if key, do: Map.put(acc, to_string(key), value), else: acc
    end)
  end

  # any - true if any element is truthy
  defp eval_func(:any, [], data, _opts) when is_list(data) do
    Enum.any?(data, &truthy?/1)
  end

  defp eval_func(:any, [expr], data, opts) when is_list(data) do
    Enum.any?(data, fn item -> truthy?(eval(expr, item, opts)) end)
  end

  # all - true if all elements are truthy
  defp eval_func(:all, [], data, _opts) when is_list(data) do
    Enum.all?(data, &truthy?/1)
  end

  defp eval_func(:all, [expr], data, opts) when is_list(data) do
    Enum.all?(data, fn item -> truthy?(eval(expr, item, opts)) end)
  end

  # range - generate sequence
  defp eval_func(:range, [n_expr], data, opts) do
    n = eval(n_expr, data, opts)
    {:multi, Enum.to_list(0..(n - 1))}
  end

  defp eval_func(:range, [from_expr, to_expr], data, opts) do
    from = eval(from_expr, data, opts)
    to = eval(to_expr, data, opts)
    {:multi, Enum.to_list(from..(to - 1))}
  end

  defp eval_func(:range, [from_expr, to_expr, step_expr], data, opts) do
    from = eval(from_expr, data, opts)
    to = eval(to_expr, data, opts)
    step = eval(step_expr, data, opts)
    {:multi, Enum.to_list(from..(to - 1)//step)}
  end

  # limit(n; expr) - take first n results from expr
  defp eval_func(:limit, [n_expr, expr], data, opts) do
    n = eval(n_expr, data, opts)
    results = eval_to_list(expr, data, opts)
    {:multi, Enum.take(results, n)}
  end

  # until(cond; update) - loop until condition true
  defp eval_func(:until, [cond_expr, update_expr], data, opts) do
    do_until(data, cond_expr, update_expr, opts)
  end

  # while(cond; update) - loop while condition true
  defp eval_func(:while, [cond_expr, update_expr], data, opts) do
    do_while(data, cond_expr, update_expr, opts, [])
  end

  # repeat(expr) - infinite repetition (use with limit)
  defp eval_func(:repeat, [expr], data, opts) do
    # We can't do infinite, but we'll do a reasonable limit
    results =
      Stream.repeatedly(fn -> eval(expr, data, opts) end)
      |> Enum.take(1000)

    {:multi, results}
  end

  # recurse - recursively apply filter
  defp eval_func(:recurse, [], data, opts) do
    eval_func(:recurse, [{:func, :recurse_default, []}], data, opts)
  end

  defp eval_func(:recurse, [expr], data, opts) do
    {:multi, do_recurse(data, expr, opts, [])}
  end

  defp eval_func(:recurse_default, [], data, opts) do
    # Default recurse filter: .[]?
    eval({:optional, :iterate}, data, opts)
  end

  # walk(f) - recursively transform
  defp eval_func(:walk, [expr], data, opts) do
    do_walk(data, expr, opts)
  end

  # indices(s) - find all indices of substring/element
  defp eval_func(:indices, [s_expr], data, opts) when is_binary(data) do
    s = eval(s_expr, data, opts)
    find_string_indices(data, s, 0, [])
  end

  defp eval_func(:indices, [s_expr], data, opts) when is_list(data) do
    s = eval(s_expr, data, opts)

    data
    |> Enum.with_index()
    |> Enum.filter(fn {item, _} -> item == s end)
    |> Enum.map(fn {_, i} -> i end)
  end

  # index(s) - first index
  defp eval_func(:index, [s_expr], data, opts) when is_binary(data) do
    s = eval(s_expr, data, opts)

    case :binary.match(data, s) do
      {pos, _} -> pos
      :nomatch -> nil
    end
  end

  defp eval_func(:index, [s_expr], data, opts) when is_list(data) do
    s = eval(s_expr, data, opts)
    Enum.find_index(data, &(&1 == s))
  end

  # rindex(s) - last index
  defp eval_func(:rindex, [s_expr], data, opts) when is_binary(data) do
    s = eval(s_expr, data, opts)
    indices = find_string_indices(data, s, 0, [])
    List.last(indices)
  end

  defp eval_func(:rindex, [s_expr], data, opts) when is_list(data) do
    s = eval(s_expr, data, opts)

    data
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {item, i} -> if item == s, do: i end)
  end

  # implode - [65,66,67] -> "ABC"
  defp eval_func(:implode, [], data, _opts) when is_list(data) do
    Enum.map_join(data, &<<&1::utf8>>)
  end

  # explode - "ABC" -> [65,66,67]
  defp eval_func(:explode, [], data, _opts) when is_binary(data) do
    data |> String.to_charlist()
  end

  # setpath(path; value)
  defp eval_func(:setpath, [path_expr, value_expr], data, opts) do
    path = eval(path_expr, data, opts)
    value = eval(value_expr, data, opts)
    set_path(data, path, value)
  end

  # delpaths(paths)
  defp eval_func(:delpaths, [paths_expr], data, opts) do
    paths = eval(paths_expr, data, opts)
    Enum.reduce(paths, data, &delete_path(&2, &1))
  end

  # test(regex) - regex match test
  defp eval_func(:test, [regex_expr], data, opts) when is_binary(data) do
    pattern = eval(regex_expr, data, opts)

    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, data)
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  defp eval_func(:test, [regex_expr, flags_expr], data, opts) when is_binary(data) do
    pattern = eval(regex_expr, data, opts)
    flags = eval(flags_expr, data, opts)
    regex_opts = parse_regex_flags(flags)

    case Regex.compile(pattern, regex_opts) do
      {:ok, regex} -> Regex.match?(regex, data)
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  # match(regex) - regex match with captures
  defp eval_func(:match, [regex_expr], data, opts) when is_binary(data) do
    pattern = eval(regex_expr, data, opts)

    case Regex.compile(pattern) do
      {:ok, regex} ->
        case Regex.run(regex, data, return: :index) do
          nil ->
            nil

          [{offset, length} | captures] ->
            %{
              "offset" => offset,
              "length" => length,
              "string" => String.slice(data, offset, length),
              "captures" =>
                Enum.map(captures, fn {o, l} ->
                  %{"offset" => o, "length" => l, "string" => String.slice(data, o, l)}
                end)
            }
        end

      {:error, _} ->
        throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  # capture(regex) - named captures
  defp eval_func(:capture, [regex_expr], data, opts) when is_binary(data) do
    pattern = eval(regex_expr, data, opts)

    case Regex.compile(pattern) do
      {:ok, regex} ->
        case Regex.named_captures(regex, data) do
          nil -> nil
          captures -> captures
        end

      {:error, _} ->
        throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  # gsub(regex; replacement) - global substitution
  defp eval_func(:gsub, [regex_expr, repl_expr], data, opts) when is_binary(data) do
    pattern = eval(regex_expr, data, opts)
    replacement = eval(repl_expr, data, opts)

    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.replace(regex, data, replacement)
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  # sub(regex; replacement) - single substitution
  defp eval_func(:sub, [regex_expr, repl_expr], data, opts) when is_binary(data) do
    pattern = eval(regex_expr, data, opts)
    replacement = eval(repl_expr, data, opts)

    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.replace(regex, data, replacement, global: false)
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  # scan(regex) - all matches
  defp eval_func(:scan, [regex_expr], data, opts) when is_binary(data) do
    pattern = eval(regex_expr, data, opts)

    case Regex.compile(pattern) do
      {:ok, regex} ->
        Regex.scan(regex, data)
        |> Enum.map(fn
          [match] -> match
          [_match | groups] -> groups
        end)

      {:error, _} ->
        throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  # splits(regex) - split keeping empty strings
  defp eval_func(:splits, [regex_expr], data, opts) when is_binary(data) do
    pattern = eval(regex_expr, data, opts)

    case Regex.compile(pattern) do
      {:ok, regex} -> {:multi, Regex.split(regex, data)}
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  # ascii - check if string is ASCII
  defp eval_func(:ascii, [], data, _opts) when is_binary(data) do
    String.valid?(data) and data == String.replace(data, ~r/[^\x00-\x7F]/, "")
  end

  # numbers - filter for numbers (used with recursive descent)
  defp eval_func(:numbers, [], data, _opts) when is_number(data), do: data
  defp eval_func(:numbers, [], _data, _opts), do: :empty

  # strings - filter for strings
  defp eval_func(:strings, [], data, _opts) when is_binary(data), do: data
  defp eval_func(:strings, [], _data, _opts), do: :empty

  # booleans - filter for booleans
  defp eval_func(:booleans, [], data, _opts) when is_boolean(data), do: data
  defp eval_func(:booleans, [], _data, _opts), do: :empty

  # nulls - filter for null
  defp eval_func(:nulls, [], nil, _opts), do: nil
  defp eval_func(:nulls, [], _data, _opts), do: :empty

  # arrays - filter for arrays
  defp eval_func(:arrays, [], data, _opts) when is_list(data), do: data
  defp eval_func(:arrays, [], _data, _opts), do: :empty

  # objects - filter for objects
  defp eval_func(:objects, [], data, _opts) when is_map(data), do: data
  defp eval_func(:objects, [], _data, _opts), do: :empty

  # iterables - filter for arrays and objects
  defp eval_func(:iterables, [], data, _opts) when is_list(data) or is_map(data), do: data
  defp eval_func(:iterables, [], _data, _opts), do: :empty

  # scalars - filter for non-iterables
  defp eval_func(:scalars, [], data, _opts)
       when not is_list(data) and not is_map(data),
       do: data

  defp eval_func(:scalars, [], _data, _opts), do: :empty

  # values - filter out null
  defp eval_func(:values, [], nil, _opts), do: :empty
  defp eval_func(:values, [], data, _opts) when is_map(data), do: Map.values(data)
  defp eval_func(:values, [], data, _opts) when is_list(data), do: data
  defp eval_func(:values, [], data, _opts), do: data

  # min_by/max_by - fix for empty arrays
  defp eval_func(:min_by, [_expr], [], _opts), do: nil
  defp eval_func(:max_by, [_expr], [], _opts), do: nil

  defp eval_func(:min_by, [expr], data, opts) when is_list(data) and data != [] do
    Enum.min_by(data, fn item -> eval(expr, item, opts) end)
  end

  defp eval_func(:max_by, [expr], data, opts) when is_list(data) and data != [] do
    Enum.max_by(data, fn item -> eval(expr, item, opts) end)
  end

  # isnan, isinfinite, isfinite, isnormal
  # Note: Elixir floats can't be NaN, so isnan is always false for actual floats
  defp eval_func(:isnan, [], :nan, _opts), do: true
  defp eval_func(:isnan, [], _data, _opts), do: false

  # Elixir doesn't have infinity/NaN, so we use special atoms and handle them
  defp eval_func(:isinfinite, [], :infinity, _opts), do: true
  defp eval_func(:isinfinite, [], :neg_infinity, _opts), do: true
  defp eval_func(:isinfinite, [], _data, _opts), do: false

  defp eval_func(:isfinite, [], :infinity, _opts), do: false
  defp eval_func(:isfinite, [], :neg_infinity, _opts), do: false
  defp eval_func(:isfinite, [], :nan, _opts), do: false
  defp eval_func(:isfinite, [], data, _opts) when is_number(data), do: true
  defp eval_func(:isfinite, [], _data, _opts), do: false

  defp eval_func(:isnormal, [], data, _opts) when is_number(data) and data != 0, do: true
  defp eval_func(:isnormal, [], _data, _opts), do: false

  # infinite/nan - we can't truly represent these in Elixir, return large numbers
  # credo:disable-for-next-line Credo.Check.Readability.LargeNumbers
  defp eval_func(:infinite, [], _data, _opts), do: 1.7976931348623157e308
  defp eval_func(:nan, [], _data, _opts), do: nil

  # builtins - list all builtin functions
  defp eval_func(:builtins, [], _data, _opts) do
    [
      "add",
      "all",
      "any",
      "arrays",
      "ascii",
      "ascii_downcase",
      "ascii_upcase",
      "booleans",
      "builtins",
      "capture",
      "ceil",
      "contains",
      "delpaths",
      "empty",
      "endswith",
      "env",
      "error",
      "explode",
      "fabs",
      "first",
      "flatten",
      "floor",
      "from_entries",
      "fromjson",
      "getpath",
      "group_by",
      "gsub",
      "has",
      "implode",
      "in",
      "index",
      "indices",
      "infinite",
      "inside",
      "isfinite",
      "isinfinite",
      "isnan",
      "isnormal",
      "iterables",
      "join",
      "keys",
      "last",
      "leaf_paths",
      "length",
      "limit",
      "ltrimstr",
      "map",
      "match",
      "max",
      "max_by",
      "min",
      "min_by",
      "nan",
      "not",
      "now",
      "nth",
      "nulls",
      "numbers",
      "objects",
      "paths",
      "range",
      "recurse",
      "repeat",
      "reverse",
      "rindex",
      "round",
      "rtrimstr",
      "scalars",
      "scan",
      "select",
      "setpath",
      "sort",
      "sort_by",
      "split",
      "splits",
      "sqrt",
      "startswith",
      "strings",
      "sub",
      "test",
      "to_entries",
      "tojson",
      "tonumber",
      "tostring",
      "type",
      "unique",
      "unique_by",
      "until",
      "values",
      "walk",
      "while",
      "with_entries"
    ]
  end

  # debug - pass through with debug output (we just pass through)
  defp eval_func(:debug, [], data, _opts), do: data

  defp eval_func(:debug, [msg_expr], data, opts) do
    _msg = eval(msg_expr, data, opts)
    data
  end

  # input/inputs - these are tricky in our context, stub them
  defp eval_func(:input, [], _data, _opts), do: :empty
  defp eval_func(:inputs, [], _data, _opts), do: {:multi, []}

  # $ENV access as a function
  defp eval_func(:env, [name_expr], data, opts) do
    name = eval(name_expr, data, opts)
    env_map = Map.get(opts, :env, %{})
    Map.get(env_map, name)
  end

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

  defp format_csv_field(nil), do: ""
  defp format_csv_field(true), do: "true"
  defp format_csv_field(false), do: "false"
  defp format_csv_field(n) when is_number(n), do: to_string(n)

  defp format_csv_field(s) when is_binary(s) do
    if String.contains?(s, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(s, "\"", "\"\"") <> "\""
    else
      s
    end
  end

  defp format_csv_field(other), do: Jason.encode!(other)

  defp format_tsv_field(nil), do: ""
  defp format_tsv_field(true), do: "true"
  defp format_tsv_field(false), do: "false"
  defp format_tsv_field(n) when is_number(n), do: to_string(n)

  defp format_tsv_field(s) when is_binary(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\t", "\\t")
    |> String.replace("\r", "\\r")
    |> String.replace("\n", "\\n")
  end

  defp format_tsv_field(other), do: Jason.encode!(other)

  defp stringify(nil), do: "null"
  defp stringify(s) when is_binary(s), do: s
  defp stringify(n) when is_number(n), do: to_string(n)
  defp stringify(true), do: "true"
  defp stringify(false), do: "false"
  defp stringify(other), do: Jason.encode!(other)

  # Helper for until loop
  defp do_until(data, cond_expr, update_expr, opts) do
    if truthy?(eval(cond_expr, data, opts)) do
      data
    else
      new_data = eval(update_expr, data, opts)
      do_until(new_data, cond_expr, update_expr, opts)
    end
  end

  # Helper for while loop
  defp do_while(data, cond_expr, update_expr, opts, acc) do
    if truthy?(eval(cond_expr, data, opts)) do
      new_data = eval(update_expr, data, opts)
      do_while(new_data, cond_expr, update_expr, opts, [data | acc])
    else
      {:multi, Enum.reverse([data | acc])}
    end
  end

  # Helper for recurse
  defp do_recurse(data, expr, opts, acc) do
    results = eval_to_list(expr, data, opts)
    results = Enum.reject(results, &(&1 == :empty))

    case results do
      [] ->
        [data | acc]

      _ ->
        nested = Enum.flat_map(results, &do_recurse(&1, expr, opts, []))
        [data | nested] ++ acc
    end
  end

  # Helper for walk - recursively transform bottom-up
  defp do_walk(data, expr, opts) when is_map(data) do
    transformed = Map.new(data, fn {k, v} -> {k, do_walk(v, expr, opts)} end)
    eval(expr, transformed, opts)
  end

  defp do_walk(data, expr, opts) when is_list(data) do
    transformed = Enum.map(data, &do_walk(&1, expr, opts))
    eval(expr, transformed, opts)
  end

  defp do_walk(data, expr, opts) do
    eval(expr, data, opts)
  end

  # Helper for finding string indices
  defp find_string_indices(string, pattern, offset, acc) do
    case :binary.match(string, pattern) do
      {pos, _len} ->
        new_offset = offset + pos + 1
        rest = :binary.part(string, pos + 1, byte_size(string) - pos - 1)
        find_string_indices(rest, pattern, new_offset, [offset + pos | acc])

      :nomatch ->
        Enum.reverse(acc)
    end
  end

  # Helper for setpath
  defp set_path(_data, [], value), do: value

  defp set_path(data, [key | rest], value) when is_map(data) and is_binary(key) do
    Map.put(data, key, set_path(Map.get(data, key, %{}), rest, value))
  end

  defp set_path(data, [idx | rest], value) when is_list(data) and is_integer(idx) do
    List.update_at(data, idx, fn existing -> set_path(existing || %{}, rest, value) end)
  end

  defp set_path(nil, [key | rest], value) when is_binary(key) do
    %{key => set_path(nil, rest, value)}
  end

  defp set_path(nil, [idx | rest], value) when is_integer(idx) do
    list = List.duplicate(nil, idx + 1)
    List.update_at(list, idx, fn _ -> set_path(nil, rest, value) end)
  end

  defp set_path(data, _, _), do: data

  # Helper for deletepath
  defp delete_path(_data, []), do: nil

  defp delete_path(data, [key]) when is_map(data) and is_binary(key) do
    Map.delete(data, key)
  end

  defp delete_path(data, [idx]) when is_list(data) and is_integer(idx) do
    List.delete_at(data, idx)
  end

  defp delete_path(data, [key | rest]) when is_map(data) and is_binary(key) do
    Map.update(data, key, nil, &delete_path(&1, rest))
  end

  defp delete_path(data, [idx | rest]) when is_list(data) and is_integer(idx) do
    List.update_at(data, idx, &delete_path(&1, rest))
  end

  defp delete_path(data, _), do: data

  # Helper for regex flags
  defp parse_regex_flags(flags) when is_binary(flags) do
    flags
    |> String.graphemes()
    |> Enum.reduce([], fn
      "i", acc -> [:caseless | acc]
      "x", acc -> [:extended | acc]
      "s", acc -> [:dotall | acc]
      "m", acc -> [:multiline | acc]
      _, acc -> acc
    end)
  end

  defp parse_regex_flags(_), do: []
end
