defmodule JustBash.Commands.Jq.Evaluator.Functions do
  @moduledoc """
  Built-in function implementations for jq.

  This module contains all the named functions available in jq expressions,
  organized by category: collection operations, string operations, type
  functions, path operations, regex operations, and iteration helpers.
  """

  @doc """
  Evaluate a function call.

  Returns the result of applying the named function with given arguments
  to the input data. Raises `{:eval_error, message}` for unknown functions.
  """
  @spec eval_func(atom(), [any()], any(), map(), module()) :: any()
  def eval_func(name, args, data, opts, evaluator) do
    do_eval_func(name, args, data, opts, evaluator)
  end

  # Collection functions
  defp do_eval_func(:keys, [], data, _opts, _eval) when is_map(data) do
    Map.keys(data) |> Enum.sort()
  end

  defp do_eval_func(:keys, [], data, _opts, _eval) when is_list(data) do
    Enum.to_list(0..(length(data) - 1))
  end

  defp do_eval_func(:values, [], data, _opts, _eval) when is_map(data), do: Map.values(data)
  defp do_eval_func(:values, [], data, _opts, _eval) when is_list(data), do: data

  defp do_eval_func(:length, [], data, _opts, _eval) when is_binary(data), do: String.length(data)
  defp do_eval_func(:length, [], data, _opts, _eval) when is_list(data), do: length(data)
  defp do_eval_func(:length, [], data, _opts, _eval) when is_map(data), do: map_size(data)
  defp do_eval_func(:length, [], nil, _opts, _eval), do: 0

  defp do_eval_func(:type, [], nil, _opts, _eval), do: "null"
  defp do_eval_func(:type, [], data, _opts, _eval) when is_boolean(data), do: "boolean"
  defp do_eval_func(:type, [], data, _opts, _eval) when is_number(data), do: "number"
  defp do_eval_func(:type, [], data, _opts, _eval) when is_binary(data), do: "string"
  defp do_eval_func(:type, [], data, _opts, _eval) when is_list(data), do: "array"
  defp do_eval_func(:type, [], data, _opts, _eval) when is_map(data), do: "object"

  defp do_eval_func(:has, [key_expr], data, opts, eval) when is_map(data) do
    key = eval.eval(key_expr, data, opts)
    Map.has_key?(data, key)
  end

  defp do_eval_func(:has, [key_expr], data, opts, eval) when is_list(data) do
    key = eval.eval(key_expr, data, opts)
    key >= 0 and key < length(data)
  end

  defp do_eval_func(:in, [container_expr], data, opts, eval) do
    container = eval.eval(container_expr, data, opts)

    cond do
      is_map(container) -> Map.has_key?(container, data)
      is_list(container) -> Enum.member?(container, data)
      true -> false
    end
  end

  defp do_eval_func(:map, [expr], data, opts, eval) when is_list(data) do
    Enum.map(data, fn item -> eval.eval(expr, item, opts) end)
  end

  defp do_eval_func(:map_values, [expr], data, opts, eval) when is_map(data) do
    Map.new(data, fn {k, v} -> {k, eval.eval(expr, v, opts)} end)
  end

  defp do_eval_func(:select, [expr], data, opts, eval) do
    val = eval.eval(expr, data, opts)
    if truthy?(val), do: data, else: :empty
  end

  defp do_eval_func(:add, [], [], _opts, _eval), do: nil

  defp do_eval_func(:add, [], data, _opts, _eval) when is_list(data) do
    cond do
      Enum.all?(data, &is_number/1) -> Enum.sum(data)
      Enum.all?(data, &is_binary/1) -> Enum.join(data)
      Enum.all?(data, &is_list/1) -> List.flatten(data)
      Enum.all?(data, &is_map/1) -> Enum.reduce(data, %{}, &Map.merge(&2, &1))
      true -> throw({:eval_error, "cannot add mixed types"})
    end
  end

  defp do_eval_func(:first, [], data, _opts, _eval) when is_list(data), do: List.first(data)

  defp do_eval_func(:first, [expr], data, opts, eval) do
    case eval.eval(expr, data, opts) do
      [h | _] -> h
      result -> result
    end
  end

  defp do_eval_func(:last, [], data, _opts, _eval) when is_list(data), do: List.last(data)

  defp do_eval_func(:last, [expr], data, opts, eval) do
    case eval.eval(expr, data, opts) do
      list when is_list(list) -> List.last(list)
      result -> result
    end
  end

  defp do_eval_func(:nth, [n_expr], data, opts, eval) when is_list(data) do
    n = eval.eval(n_expr, data, opts)
    Enum.at(data, n)
  end

  defp do_eval_func(:flatten, [], data, _opts, _eval) when is_list(data), do: List.flatten(data)

  defp do_eval_func(:flatten, [depth_expr], data, opts, eval) when is_list(data) do
    depth = eval.eval(depth_expr, data, opts)
    flatten_to_depth(data, depth)
  end

  defp do_eval_func(:reverse, [], data, _opts, _eval) when is_list(data), do: Enum.reverse(data)

  defp do_eval_func(:reverse, [], data, _opts, _eval) when is_binary(data),
    do: String.reverse(data)

  defp do_eval_func(:sort, [], data, _opts, _eval) when is_list(data), do: Enum.sort(data)

  defp do_eval_func(:sort_by, [expr], data, opts, eval) when is_list(data) do
    Enum.sort_by(data, fn item -> eval.eval(expr, item, opts) end)
  end

  defp do_eval_func(:unique, [], data, _opts, _eval) when is_list(data), do: Enum.uniq(data)

  defp do_eval_func(:unique_by, [expr], data, opts, eval) when is_list(data) do
    Enum.uniq_by(data, fn item -> eval.eval(expr, item, opts) end)
  end

  defp do_eval_func(:group_by, [expr], data, opts, eval) when is_list(data) do
    data
    |> Enum.group_by(fn item -> eval.eval(expr, item, opts) end)
    |> Map.values()
  end

  defp do_eval_func(:min, [], data, _opts, _eval) when is_list(data) and data != [],
    do: Enum.min(data)

  defp do_eval_func(:min, [], [], _opts, _eval), do: nil

  defp do_eval_func(:max, [], data, _opts, _eval) when is_list(data) and data != [],
    do: Enum.max(data)

  defp do_eval_func(:max, [], [], _opts, _eval), do: nil

  defp do_eval_func(:min_by, [_expr], [], _opts, _eval), do: nil

  defp do_eval_func(:min_by, [expr], data, opts, eval) when is_list(data) and data != [] do
    Enum.min_by(data, fn item -> eval.eval(expr, item, opts) end)
  end

  defp do_eval_func(:max_by, [_expr], [], _opts, _eval), do: nil

  defp do_eval_func(:max_by, [expr], data, opts, eval) when is_list(data) and data != [] do
    Enum.max_by(data, fn item -> eval.eval(expr, item, opts) end)
  end

  defp do_eval_func(:contains, [other_expr], data, opts, eval) do
    other = eval.eval(other_expr, data, opts)
    json_contains?(data, other)
  end

  defp do_eval_func(:inside, [other_expr], data, opts, eval) do
    other = eval.eval(other_expr, data, opts)
    json_contains?(other, data)
  end

  # String functions
  defp do_eval_func(:split, [sep_expr], data, opts, eval) when is_binary(data) do
    sep = eval.eval(sep_expr, data, opts)
    String.split(data, sep)
  end

  defp do_eval_func(:join, [sep_expr], data, opts, eval) when is_list(data) do
    sep = eval.eval(sep_expr, data, opts)
    Enum.map_join(data, sep, &to_string/1)
  end

  defp do_eval_func(:ascii_downcase, [], data, _opts, _eval) when is_binary(data) do
    String.downcase(data)
  end

  defp do_eval_func(:ascii_upcase, [], data, _opts, _eval) when is_binary(data) do
    String.upcase(data)
  end

  defp do_eval_func(:ltrimstr, [prefix_expr], data, opts, eval) when is_binary(data) do
    prefix = eval.eval(prefix_expr, data, opts)
    if String.starts_with?(data, prefix), do: String.replace_prefix(data, prefix, ""), else: data
  end

  defp do_eval_func(:rtrimstr, [suffix_expr], data, opts, eval) when is_binary(data) do
    suffix = eval.eval(suffix_expr, data, opts)
    if String.ends_with?(data, suffix), do: String.replace_suffix(data, suffix, ""), else: data
  end

  defp do_eval_func(:startswith, [prefix_expr], data, opts, eval) when is_binary(data) do
    prefix = eval.eval(prefix_expr, data, opts)
    String.starts_with?(data, prefix)
  end

  defp do_eval_func(:endswith, [suffix_expr], data, opts, eval) when is_binary(data) do
    suffix = eval.eval(suffix_expr, data, opts)
    String.ends_with?(data, suffix)
  end

  defp do_eval_func(:implode, [], data, _opts, _eval) when is_list(data) do
    Enum.map_join(data, &<<&1::utf8>>)
  end

  defp do_eval_func(:explode, [], data, _opts, _eval) when is_binary(data) do
    String.to_charlist(data)
  end

  # Type conversion functions
  defp do_eval_func(:tostring, [], data, _opts, _eval) do
    cond do
      is_binary(data) -> data
      is_nil(data) -> "null"
      true -> Jason.encode!(data)
    end
  end

  defp do_eval_func(:tonumber, [], data, _opts, _eval) when is_number(data), do: data

  defp do_eval_func(:tonumber, [], data, _opts, _eval) when is_binary(data) do
    case Float.parse(data) do
      {n, ""} -> if n == trunc(n), do: trunc(n), else: n
      _ -> throw({:eval_error, "cannot parse number: #{data}"})
    end
  end

  defp do_eval_func(:tojson, [], data, _opts, _eval), do: Jason.encode!(data)

  defp do_eval_func(:fromjson, [], data, _opts, _eval) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, result} -> result
      {:error, _} -> throw({:eval_error, "invalid JSON"})
    end
  end

  # Logic functions
  defp do_eval_func(:not, [], data, _opts, _eval), do: not truthy?(data)

  defp do_eval_func(:error, [msg_expr], data, opts, eval) do
    msg = eval.eval(msg_expr, data, opts)
    throw({:eval_error, to_string(msg)})
  end

  defp do_eval_func(:error, [], _data, _opts, _eval), do: throw({:eval_error, "error"})

  # Path functions
  defp do_eval_func(:getpath, [path_expr], data, opts, eval) do
    path = eval.eval(path_expr, data, opts)
    get_path(data, path)
  end

  defp do_eval_func(:paths, [], data, _opts, _eval), do: get_all_paths(data, [])

  defp do_eval_func(:leaf_paths, [], data, _opts, _eval) do
    get_all_paths(data, [])
    |> Enum.filter(fn path ->
      val = get_path(data, path)
      not is_map(val) and not is_list(val)
    end)
  end

  defp do_eval_func(:setpath, [path_expr, value_expr], data, opts, eval) do
    path = eval.eval(path_expr, data, opts)
    value = eval.eval(value_expr, data, opts)
    set_path(data, path, value)
  end

  defp do_eval_func(:delpaths, [paths_expr], data, opts, eval) do
    paths = eval.eval(paths_expr, data, opts)
    Enum.reduce(paths, data, &delete_path(&2, &1))
  end

  # Environment and time
  defp do_eval_func(:env, [], _data, opts, _eval), do: Map.get(opts, :env, %{})

  defp do_eval_func(:env, [name_expr], data, opts, eval) do
    name = eval.eval(name_expr, data, opts)
    env_map = Map.get(opts, :env, %{})
    Map.get(env_map, name)
  end

  defp do_eval_func(:now, [], _data, _opts, _eval) do
    DateTime.utc_now() |> DateTime.to_unix()
  end

  # Math functions
  defp do_eval_func(:floor, [], data, _opts, _eval) when is_number(data), do: floor(data)
  defp do_eval_func(:ceil, [], data, _opts, _eval) when is_number(data), do: ceil(data)
  defp do_eval_func(:round, [], data, _opts, _eval) when is_number(data), do: round(data)
  defp do_eval_func(:fabs, [], data, _opts, _eval) when is_number(data), do: abs(data)
  defp do_eval_func(:sqrt, [], data, _opts, _eval) when is_number(data), do: :math.sqrt(data)

  # Entry functions
  defp do_eval_func(:to_entries, [], data, _opts, _eval) when is_map(data) do
    Enum.map(data, fn {k, v} -> %{"key" => k, "value" => v} end)
  end

  defp do_eval_func(:from_entries, [], data, _opts, _eval) when is_list(data) do
    Enum.reduce(data, %{}, fn entry, acc ->
      key = Map.get(entry, "key") || Map.get(entry, "k") || Map.get(entry, "name")
      value = Map.get(entry, "value") || Map.get(entry, "v")
      if key, do: Map.put(acc, to_string(key), value), else: acc
    end)
  end

  defp do_eval_func(:with_entries, [expr], data, opts, eval) when is_map(data) do
    entries = Enum.map(data, fn {k, v} -> %{"key" => k, "value" => v} end)
    transformed = Enum.map(entries, fn entry -> eval.eval(expr, entry, opts) end)

    Enum.reduce(transformed, %{}, fn entry, acc ->
      key = Map.get(entry, "key") || Map.get(entry, "k") || Map.get(entry, "name")
      value = Map.get(entry, "value") || Map.get(entry, "v")
      if key, do: Map.put(acc, to_string(key), value), else: acc
    end)
  end

  # Predicate functions
  defp do_eval_func(:any, [], data, _opts, _eval) when is_list(data) do
    Enum.any?(data, &truthy?/1)
  end

  defp do_eval_func(:any, [expr], data, opts, eval) when is_list(data) do
    Enum.any?(data, fn item -> truthy?(eval.eval(expr, item, opts)) end)
  end

  defp do_eval_func(:all, [], data, _opts, _eval) when is_list(data) do
    Enum.all?(data, &truthy?/1)
  end

  defp do_eval_func(:all, [expr], data, opts, eval) when is_list(data) do
    Enum.all?(data, fn item -> truthy?(eval.eval(expr, item, opts)) end)
  end

  # Range functions
  defp do_eval_func(:range, [n_expr], data, opts, eval) do
    n = eval.eval(n_expr, data, opts)
    {:multi, Enum.to_list(0..(n - 1))}
  end

  defp do_eval_func(:range, [from_expr, to_expr], data, opts, eval) do
    from = eval.eval(from_expr, data, opts)
    to = eval.eval(to_expr, data, opts)
    {:multi, Enum.to_list(from..(to - 1))}
  end

  defp do_eval_func(:range, [from_expr, to_expr, step_expr], data, opts, eval) do
    from = eval.eval(from_expr, data, opts)
    to = eval.eval(to_expr, data, opts)
    step = eval.eval(step_expr, data, opts)
    {:multi, Enum.to_list(from..(to - 1)//step)}
  end

  # Iteration functions
  defp do_eval_func(:limit, [n_expr, expr], data, opts, eval) do
    n = eval.eval(n_expr, data, opts)
    results = eval.eval_to_list(expr, data, opts)
    {:multi, Enum.take(results, n)}
  end

  defp do_eval_func(:until, [cond_expr, update_expr], data, opts, eval) do
    do_until(data, cond_expr, update_expr, opts, eval)
  end

  defp do_eval_func(:while, [cond_expr, update_expr], data, opts, eval) do
    do_while(data, cond_expr, update_expr, opts, eval, [])
  end

  defp do_eval_func(:repeat, [expr], data, opts, eval) do
    results =
      Stream.repeatedly(fn -> eval.eval(expr, data, opts) end)
      |> Enum.take(1000)

    {:multi, results}
  end

  defp do_eval_func(:recurse, [], data, opts, eval) do
    do_eval_func(:recurse, [{:func, :recurse_default, []}], data, opts, eval)
  end

  defp do_eval_func(:recurse, [expr], data, opts, eval) do
    {:multi, do_recurse(data, expr, opts, eval, [])}
  end

  defp do_eval_func(:recurse_default, [], data, opts, eval) do
    eval.eval({:optional, :iterate}, data, opts)
  end

  defp do_eval_func(:walk, [expr], data, opts, eval) do
    do_walk(data, expr, opts, eval)
  end

  # Index functions
  defp do_eval_func(:indices, [s_expr], data, opts, eval) when is_binary(data) do
    s = eval.eval(s_expr, data, opts)
    find_string_indices(data, s, 0, [])
  end

  defp do_eval_func(:indices, [s_expr], data, opts, eval) when is_list(data) do
    s = eval.eval(s_expr, data, opts)

    data
    |> Enum.with_index()
    |> Enum.filter(fn {item, _} -> item == s end)
    |> Enum.map(fn {_, i} -> i end)
  end

  defp do_eval_func(:index, [s_expr], data, opts, eval) when is_binary(data) do
    s = eval.eval(s_expr, data, opts)

    case :binary.match(data, s) do
      {pos, _} -> pos
      :nomatch -> nil
    end
  end

  defp do_eval_func(:index, [s_expr], data, opts, eval) when is_list(data) do
    s = eval.eval(s_expr, data, opts)
    Enum.find_index(data, &(&1 == s))
  end

  defp do_eval_func(:rindex, [s_expr], data, opts, eval) when is_binary(data) do
    s = eval.eval(s_expr, data, opts)
    indices = find_string_indices(data, s, 0, [])
    List.last(indices)
  end

  defp do_eval_func(:rindex, [s_expr], data, opts, eval) when is_list(data) do
    s = eval.eval(s_expr, data, opts)

    data
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {item, i} -> if item == s, do: i end)
  end

  # Regex functions
  defp do_eval_func(:test, [regex_expr], data, opts, eval) when is_binary(data) do
    pattern = eval.eval(regex_expr, data, opts)

    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, data)
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  defp do_eval_func(:test, [regex_expr, flags_expr], data, opts, eval) when is_binary(data) do
    pattern = eval.eval(regex_expr, data, opts)
    flags = eval.eval(flags_expr, data, opts)
    regex_opts = parse_regex_flags(flags)

    case Regex.compile(pattern, regex_opts) do
      {:ok, regex} -> Regex.match?(regex, data)
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  defp do_eval_func(:match, [regex_expr], data, opts, eval) when is_binary(data) do
    pattern = eval.eval(regex_expr, data, opts)

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

  defp do_eval_func(:capture, [regex_expr], data, opts, eval) when is_binary(data) do
    pattern = eval.eval(regex_expr, data, opts)

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

  defp do_eval_func(:gsub, [regex_expr, repl_expr], data, opts, eval) when is_binary(data) do
    pattern = eval.eval(regex_expr, data, opts)
    replacement = eval.eval(repl_expr, data, opts)

    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.replace(regex, data, replacement)
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  defp do_eval_func(:sub, [regex_expr, repl_expr], data, opts, eval) when is_binary(data) do
    pattern = eval.eval(regex_expr, data, opts)
    replacement = eval.eval(repl_expr, data, opts)

    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.replace(regex, data, replacement, global: false)
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  defp do_eval_func(:scan, [regex_expr], data, opts, eval) when is_binary(data) do
    pattern = eval.eval(regex_expr, data, opts)

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

  defp do_eval_func(:splits, [regex_expr], data, opts, eval) when is_binary(data) do
    pattern = eval.eval(regex_expr, data, opts)

    case Regex.compile(pattern) do
      {:ok, regex} -> {:multi, Regex.split(regex, data)}
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  # Type filter functions
  defp do_eval_func(:ascii, [], data, _opts, _eval) when is_binary(data) do
    String.valid?(data) and data == String.replace(data, ~r/[^\x00-\x7F]/, "")
  end

  defp do_eval_func(:numbers, [], data, _opts, _eval) when is_number(data), do: data
  defp do_eval_func(:numbers, [], _data, _opts, _eval), do: :empty

  defp do_eval_func(:strings, [], data, _opts, _eval) when is_binary(data), do: data
  defp do_eval_func(:strings, [], _data, _opts, _eval), do: :empty

  defp do_eval_func(:booleans, [], data, _opts, _eval) when is_boolean(data), do: data
  defp do_eval_func(:booleans, [], _data, _opts, _eval), do: :empty

  defp do_eval_func(:nulls, [], nil, _opts, _eval), do: nil
  defp do_eval_func(:nulls, [], _data, _opts, _eval), do: :empty

  defp do_eval_func(:arrays, [], data, _opts, _eval) when is_list(data), do: data
  defp do_eval_func(:arrays, [], _data, _opts, _eval), do: :empty

  defp do_eval_func(:objects, [], data, _opts, _eval) when is_map(data), do: data
  defp do_eval_func(:objects, [], _data, _opts, _eval), do: :empty

  defp do_eval_func(:iterables, [], data, _opts, _eval) when is_list(data) or is_map(data),
    do: data

  defp do_eval_func(:iterables, [], _data, _opts, _eval), do: :empty

  defp do_eval_func(:scalars, [], data, _opts, _eval)
       when not is_list(data) and not is_map(data),
       do: data

  defp do_eval_func(:scalars, [], _data, _opts, _eval), do: :empty

  defp do_eval_func(:values, [], nil, _opts, _eval), do: :empty
  defp do_eval_func(:values, [], data, _opts, _eval) when is_map(data), do: Map.values(data)
  defp do_eval_func(:values, [], data, _opts, _eval) when is_list(data), do: data
  defp do_eval_func(:values, [], data, _opts, _eval), do: data

  # Special number functions
  defp do_eval_func(:isnan, [], :nan, _opts, _eval), do: true
  defp do_eval_func(:isnan, [], _data, _opts, _eval), do: false

  defp do_eval_func(:isinfinite, [], :infinity, _opts, _eval), do: true
  defp do_eval_func(:isinfinite, [], :neg_infinity, _opts, _eval), do: true
  defp do_eval_func(:isinfinite, [], _data, _opts, _eval), do: false

  defp do_eval_func(:isfinite, [], :infinity, _opts, _eval), do: false
  defp do_eval_func(:isfinite, [], :neg_infinity, _opts, _eval), do: false
  defp do_eval_func(:isfinite, [], :nan, _opts, _eval), do: false
  defp do_eval_func(:isfinite, [], data, _opts, _eval) when is_number(data), do: true
  defp do_eval_func(:isfinite, [], _data, _opts, _eval), do: false

  defp do_eval_func(:isnormal, [], data, _opts, _eval) when is_number(data) and data != 0,
    do: true

  defp do_eval_func(:isnormal, [], _data, _opts, _eval), do: false

  # credo:disable-for-next-line Credo.Check.Readability.LargeNumbers
  defp do_eval_func(:infinite, [], _data, _opts, _eval), do: 1.7976931348623157e308
  defp do_eval_func(:nan, [], _data, _opts, _eval), do: nil

  # Meta functions
  defp do_eval_func(:builtins, [], _data, _opts, _eval), do: builtins_list()

  defp do_eval_func(:debug, [], data, _opts, _eval), do: data

  defp do_eval_func(:debug, [msg_expr], data, opts, eval) do
    _msg = eval.eval(msg_expr, data, opts)
    data
  end

  defp do_eval_func(:input, [], _data, _opts, _eval), do: :empty
  defp do_eval_func(:inputs, [], _data, _opts, _eval), do: {:multi, []}

  defp do_eval_func(name, _args, _data, _opts, _eval) do
    throw({:eval_error, "unknown function: #{name}"})
  end

  # Helper functions

  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true

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

  defp do_until(data, cond_expr, update_expr, opts, eval) do
    if truthy?(eval.eval(cond_expr, data, opts)) do
      data
    else
      new_data = eval.eval(update_expr, data, opts)
      do_until(new_data, cond_expr, update_expr, opts, eval)
    end
  end

  defp do_while(data, cond_expr, update_expr, opts, eval, acc) do
    if truthy?(eval.eval(cond_expr, data, opts)) do
      new_data = eval.eval(update_expr, data, opts)
      do_while(new_data, cond_expr, update_expr, opts, eval, [data | acc])
    else
      {:multi, Enum.reverse([data | acc])}
    end
  end

  defp do_recurse(data, expr, opts, eval, acc) do
    results = eval.eval_to_list(expr, data, opts)
    results = Enum.reject(results, &(&1 == :empty))

    case results do
      [] ->
        [data | acc]

      _ ->
        nested = Enum.flat_map(results, &do_recurse(&1, expr, opts, eval, []))
        [data | nested] ++ acc
    end
  end

  defp do_walk(data, expr, opts, eval) when is_map(data) do
    transformed = Map.new(data, fn {k, v} -> {k, do_walk(v, expr, opts, eval)} end)
    eval.eval(expr, transformed, opts)
  end

  defp do_walk(data, expr, opts, eval) when is_list(data) do
    transformed = Enum.map(data, &do_walk(&1, expr, opts, eval))
    eval.eval(expr, transformed, opts)
  end

  defp do_walk(data, expr, opts, eval) do
    eval.eval(expr, data, opts)
  end

  defp builtins_list do
    ~w(
      add all any arrays ascii ascii_downcase ascii_upcase booleans builtins
      capture ceil contains delpaths empty endswith env error explode fabs
      first flatten floor from_entries fromjson getpath group_by gsub has
      implode in index indices infinite inside isfinite isinfinite isnan
      isnormal iterables join keys last leaf_paths length limit ltrimstr map
      match max max_by min min_by nan not now nth nulls numbers objects paths
      range recurse repeat reverse rindex round rtrimstr scalars scan select
      setpath sort sort_by split splits sqrt startswith strings sub test
      to_entries tojson tonumber tostring type unique unique_by until values
      walk while with_entries
    )
  end
end
