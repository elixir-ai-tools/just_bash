defmodule JustBash.Commands.Jq.Evaluator.Functions do
  @moduledoc """
  Built-in function implementations for jq.

  This module contains all the named functions available in jq expressions,
  organized by category: collection operations, string operations, type
  functions, path operations, regex operations, and iteration helpers.
  """

  alias JustBash.Commands.Jq.Evaluator

  # jq depth limit for tojson: structures at depth > 10000 get skipped
  @tojson_depth_limit 10_001

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
    if data == [], do: [], else: Enum.to_list(0..(length(data) - 1))
  end

  defp do_eval_func(:keys_unsorted, [], data, _opts, _eval) when is_map(data) do
    Map.keys(data)
  end

  defp do_eval_func(:values, [], nil, _opts, _eval), do: :empty
  defp do_eval_func(:values, [], data, _opts, _eval), do: data

  defp do_eval_func(:length, [], :nan, _opts, _eval), do: :nan

  defp do_eval_func(:length, [], data, _opts, _eval) when is_binary(data),
    do: String.length(data)

  defp do_eval_func(:length, [], data, _opts, _eval) when is_list(data), do: length(data)
  defp do_eval_func(:length, [], data, _opts, _eval) when is_map(data), do: map_size(data)
  defp do_eval_func(:length, [], nil, _opts, _eval), do: 0
  defp do_eval_func(:length, [], data, _opts, _eval) when is_number(data), do: abs(data)

  defp do_eval_func(:utf8bytelength, [], data, _opts, _eval) when is_binary(data) do
    byte_size(data)
  end

  defp do_eval_func(:utf8bytelength, [], data, _opts, _eval) do
    desc = jq_value_desc(data)
    throw({:eval_error, "#{desc} only strings have UTF-8 byte length"})
  end

  defp do_eval_func(:type, [], :nan, _opts, _eval), do: "number"
  defp do_eval_func(:type, [], nil, _opts, _eval), do: "null"
  defp do_eval_func(:type, [], data, _opts, _eval) when is_boolean(data), do: "boolean"
  defp do_eval_func(:type, [], data, _opts, _eval) when is_number(data), do: "number"
  defp do_eval_func(:type, [], data, _opts, _eval) when is_binary(data), do: "string"
  defp do_eval_func(:type, [], data, _opts, _eval) when is_list(data), do: "array"
  defp do_eval_func(:type, [], data, _opts, _eval) when is_map(data), do: "object"

  defp do_eval_func(:type_error, [], data, _opts, _eval) do
    t = type_name(data)
    throw({:eval_error, "#{t} is not valid in a #{t} context"})
  end

  defp do_eval_func(:has, [key_expr], data, opts, eval) when is_map(data) do
    key = eval.eval(key_expr, data, opts)
    Map.has_key?(data, key)
  end

  defp do_eval_func(:has, [key_expr], data, opts, eval) when is_list(data) do
    key = eval.eval(key_expr, data, opts)
    is_integer(key) and key >= 0 and key < length(data)
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
    Enum.flat_map(data, fn item ->
      case eval.eval(expr, item, opts) do
        {:multi, items} -> items
        :empty -> []
        item -> [item]
      end
    end)
  end

  defp do_eval_func(:map_values, [expr], data, opts, eval) when is_map(data) do
    Map.new(data, fn {k, v} -> {k, eval.eval(expr, v, opts)} end)
  end

  defp do_eval_func(:map_values, [expr], data, opts, eval) when is_list(data) do
    Enum.map(data, fn item -> eval.eval(expr, item, opts) end)
  end

  defp do_eval_func(:select, [expr], data, opts, eval) do
    val = eval.eval(expr, data, opts)
    if truthy?(val), do: data, else: :empty
  end

  defp do_eval_func(:add, [], nil, _opts, _eval), do: nil
  defp do_eval_func(:add, [], [], _opts, _eval), do: nil

  defp do_eval_func(:add, [], data, _opts, _eval) when is_list(data) do
    add_values(data)
  end

  # add with 1 arg: add(expr) — sum of generator
  defp do_eval_func(:add, [expr], data, opts, eval) do
    results = eval.eval_to_list(expr, data, opts)
    results = Enum.reject(results, &(&1 == :empty))
    add_values(results)
  end

  defp do_eval_func(:first, [], data, _opts, _eval) when is_list(data), do: List.first(data)

  defp do_eval_func(:first, [expr], data, opts, eval) do
    case eval.eval_generator_take(expr, data, opts, 1) do
      {:ok, [h | _]} -> h
      {:ok, []} -> :empty
      {:error, _reason, [h | _]} -> h
      {:error, reason, []} -> throw({:eval_error, reason})
    end
  end

  defp do_eval_func(:last, [], data, _opts, _eval) when is_list(data), do: List.last(data)

  defp do_eval_func(:last, [expr], data, opts, eval) do
    case eval.eval_generator_take(expr, data, opts, :all) do
      {:ok, []} -> :empty
      {:ok, results} -> List.last(results)
      {:error, _reason, []} -> :empty
      {:error, _reason, results} -> List.last(results)
    end
  end

  defp do_eval_func(:nth, [n_expr], data, opts, eval) when is_list(data) do
    n = eval.eval(n_expr, data, opts)
    Enum.at(data, n)
  end

  # nth(n; expr) - get nth output of generator
  defp do_eval_func(:nth, [n_expr, gen_expr], data, opts, eval) do
    n = eval.eval(n_expr, data, opts)

    case n do
      {:multi, ns} ->
        results =
          Enum.flat_map(ns, fn ni ->
            case do_eval_func(:nth, [{:literal, ni}, gen_expr], data, opts, eval) do
              :empty -> []
              {:multi, items} -> items
              item -> [item]
            end
          end)

        {:multi, results}

      _ ->
        if is_number(n) and n < 0 do
          throw({:eval_error, "nth doesn't support negative indices"})
        end

        needed = trunc(n) + 1

        case eval.eval_generator_take(gen_expr, data, opts, needed) do
          {:ok, results} ->
            results = Enum.reject(results, &(&1 == :empty))
            if trunc(n) >= length(results), do: :empty, else: Enum.at(results, trunc(n))

          {:error, reason, results} ->
            results = Enum.reject(results, &(&1 == :empty))

            if trunc(n) < length(results) do
              Enum.at(results, trunc(n))
            else
              throw({:eval_error, reason})
            end
        end
    end
  end

  defp do_eval_func(:flatten, [], data, _opts, _eval) when is_list(data), do: deep_flatten(data)

  defp do_eval_func(:flatten, [depth_expr], data, opts, eval) when is_list(data) do
    depth = eval.eval(depth_expr, data, opts)

    if depth < 0 do
      throw({:eval_error, "flatten depth must not be negative"})
    else
      flatten_to_depth(data, depth)
    end
  end

  defp do_eval_func(:reverse, [], data, _opts, _eval) when is_list(data), do: Enum.reverse(data)

  defp do_eval_func(:reverse, [], data, _opts, _eval) when is_binary(data),
    do: String.reverse(data)

  defp do_eval_func(:sort, [], data, _opts, _eval) when is_list(data) do
    Enum.sort(data, &jq_less_or_equal?/2)
  end

  defp do_eval_func(:sort_by, [expr], data, opts, eval) when is_list(data) do
    Enum.sort_by(
      data,
      fn item ->
        case eval.eval(expr, item, opts) do
          {:multi, items} -> items
          other -> other
        end
      end,
      &jq_less_or_equal?/2
    )
  end

  defp do_eval_func(:unique, [], data, _opts, _eval) when is_list(data) do
    data
    |> Enum.sort(&jq_less_or_equal?/2)
    |> Enum.dedup()
  end

  defp do_eval_func(:unique_by, [expr], data, opts, eval) when is_list(data) do
    data
    |> Enum.sort_by(fn item -> eval.eval(expr, item, opts) end, &jq_less_or_equal?/2)
    |> Enum.dedup_by(fn item -> eval.eval(expr, item, opts) end)
  end

  defp do_eval_func(:group_by, [expr], data, opts, eval) when is_list(data) do
    data
    |> Enum.sort_by(fn item -> eval.eval(expr, item, opts) end, &jq_less_or_equal?/2)
    |> Enum.chunk_by(fn item -> eval.eval(expr, item, opts) end)
  end

  defp do_eval_func(:min, [], data, _opts, _eval) when is_list(data) and data != [] do
    Enum.sort(data, &jq_less_or_equal?/2) |> List.first()
  end

  defp do_eval_func(:min, [], [], _opts, _eval), do: nil

  defp do_eval_func(:max, [], data, _opts, _eval) when is_list(data) and data != [] do
    Enum.sort(data, &jq_less_or_equal?/2) |> List.last()
  end

  defp do_eval_func(:max, [], [], _opts, _eval), do: nil

  defp do_eval_func(:min_by, [_expr], [], _opts, _eval), do: nil

  defp do_eval_func(:min_by, [expr], data, opts, eval) when is_list(data) and data != [] do
    Enum.sort_by(data, fn item -> eval.eval(expr, item, opts) end, &jq_less_or_equal?/2)
    |> List.first()
  end

  defp do_eval_func(:max_by, [_expr], [], _opts, _eval), do: nil

  defp do_eval_func(:max_by, [expr], data, opts, eval) when is_list(data) and data != [] do
    Enum.sort_by(data, fn item -> eval.eval(expr, item, opts) end, &jq_less_or_equal?/2)
    |> List.last()
  end

  defp do_eval_func(:contains, [other_expr], data, opts, eval) do
    other = eval.eval(other_expr, data, opts)
    json_contains?(data, other)
  end

  defp do_eval_func(:inside, [other_expr], data, opts, eval) do
    other = eval.eval(other_expr, data, opts)
    json_contains?(other, data)
  end

  defp do_eval_func(:transpose, [], data, _opts, _eval) when is_list(data) do
    max_len =
      Enum.reduce(data, 0, fn
        arr, acc when is_list(arr) -> max(acc, length(arr))
        _, acc -> acc
      end)

    if max_len == 0 do
      []
    else
      for i <- 0..(max_len - 1) do
        Enum.map(data, fn
          arr when is_list(arr) -> Enum.at(arr, i)
          _ -> nil
        end)
      end
    end
  end

  defp do_eval_func(:pick, [expr], data, opts, eval) do
    # pick uses path() to get paths from the expression
    paths =
      case eval.eval({:func, :path, [expr]}, data, opts) do
        {:multi, items} -> items
        :empty -> []
        item -> [item]
      end

    paths = Enum.reject(paths, &(&1 == :empty))

    init =
      cond do
        is_map(data) -> %{}
        is_list(data) -> []
        true -> %{}
      end

    Enum.reduce(paths, init, fn path, acc ->
      path = if is_list(path), do: path, else: [path]
      val = get_path(data, path)
      set_path(acc, path, val)
    end)
  end

  # IN function: IN(expr) — check if . is in the outputs of expr
  defp do_eval_func(:IN, [expr], data, opts, eval) do
    results = eval.eval_to_list(expr, data, opts)
    results = Enum.reject(results, &(&1 == :empty))
    Enum.member?(results, data)
  end

  # IN(gen; set) — reduce: check if ANY output of gen is in the outputs of set
  # Defined as: reduce gen as $x (false; . or ($x | IN(set)))
  defp do_eval_func(:IN, [gen_expr, set_expr], data, opts, eval) do
    gen_values = eval.eval_to_list(gen_expr, data, opts)
    gen_values = Enum.reject(gen_values, &(&1 == :empty))

    Enum.reduce_while(gen_values, false, fn val, _acc ->
      set_values = eval.eval_to_list(set_expr, val, opts)
      set_values = Enum.reject(set_values, &(&1 == :empty))

      if Enum.member?(set_values, val) do
        {:halt, true}
      else
        {:cont, false}
      end
    end)
  end

  # INDEX(gen; key_expr) — create an object indexed by key
  defp do_eval_func(:INDEX, [gen_expr, key_expr], data, opts, eval) do
    items = eval.eval_to_list(gen_expr, data, opts)
    items = Enum.reject(items, &(&1 == :empty))

    Enum.reduce(items, %{}, fn item, acc ->
      key = eval.eval(key_expr, item, opts)
      key_str = if is_binary(key), do: key, else: to_string(key)
      Map.put(acc, key_str, item)
    end)
  end

  # JOIN(index_obj; key_expr) — join array elements with an index
  defp do_eval_func(:JOIN, [index_expr, key_expr], data, opts, eval) when is_list(data) do
    index = eval.eval(index_expr, data, opts)

    Enum.map(data, fn item ->
      key = eval.eval(key_expr, item, opts)
      key_str = if is_binary(key), do: key, else: to_string(key)
      [item, Map.get(index, key_str)]
    end)
  end

  # isempty(expr)
  defp do_eval_func(:isempty, [expr], data, opts, eval) do
    # isempty short-circuits: if any value is produced, return false
    # even if later values would error
    case eval.eval_generator_take(expr, data, opts, 1) do
      {:ok, []} -> true
      {:ok, _} -> false
      {:error, _reason, []} -> true
      {:error, _reason, _results} -> false
    end
  end

  # del(expr) — delete paths
  defp do_eval_func(:del, [expr], data, opts, eval) do
    # Get the paths that expr produces
    paths = get_expr_paths(expr, data, opts, eval)

    # If no paths, return data unchanged (e.g. del(empty))
    if paths == [] do
      data
    else
      del_paths(data, paths)
    end
  end

  # skip(n; expr)
  defp do_eval_func(:skip, [n_expr, gen_expr], data, opts, eval) do
    n = eval.eval(n_expr, data, opts)

    if is_number(n) and n < 0 do
      throw({:eval_error, "skip doesn't support negative count"})
    end

    n = if is_number(n), do: trunc(n), else: n
    results = eval.eval_to_list(gen_expr, data, opts)
    results = Enum.reject(results, &(&1 == :empty))
    {:multi, Enum.drop(results, n)}
  end

  # bsearch(x) — binary search on sorted array
  defp do_eval_func(:bsearch, [x_expr], data, opts, eval) when is_list(data) do
    x = eval.eval(x_expr, data, opts)
    # Convert to tuple for O(1) element access, making bsearch O(log n)
    tuple = List.to_tuple(data)
    do_bsearch(tuple, x, 0, tuple_size(tuple) - 1)
  end

  defp do_eval_func(:bsearch, [_x_expr], data, _opts, _eval) do
    throw({:eval_error, "#{jq_value_desc(data)} cannot be searched from"})
  end

  # String functions
  defp do_eval_func(:split, [sep_expr], data, opts, eval) when is_binary(data) do
    sep = eval.eval(sep_expr, data, opts)

    cond do
      is_binary(sep) and sep == "" ->
        # split("") splits into individual codepoints
        String.codepoints(data)

      is_binary(sep) ->
        String.split(data, sep)

      is_nil(sep) ->
        String.graphemes(data)

      true ->
        throw({:eval_error, "split: argument must be string"})
    end
  end

  # split with flags (regex split)
  defp do_eval_func(:split, [regex_expr, flags_expr], data, opts, eval) when is_binary(data) do
    pattern = eval.eval(regex_expr, data, opts)
    flags = eval.eval(flags_expr, data, opts)
    regex_opts = parse_regex_flags(flags)

    case Regex.compile(pattern, regex_opts) do
      {:ok, regex} -> Regex.split(regex, data)
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  defp do_eval_func(:join, [sep_expr], data, opts, eval) when is_list(data) do
    sep = eval.eval(sep_expr, data, opts)

    # Build output using IOData for O(n) performance instead of O(n^2) string concat.
    # jq's join errors when encountering non-scalar types, so we must check each element.
    result =
      Enum.reduce(data, {[], false}, fn item, {acc, has_prev} ->
        str =
          case item do
            nil ->
              ""

            n when is_number(n) ->
              to_string(n)

            s when is_binary(s) ->
              s

            b when is_boolean(b) ->
              to_string(b)

            other ->
              str_so_far = IO.iodata_to_binary(acc) <> if(has_prev, do: sep, else: "")
              other_json = Jason.encode!(other)
              other_desc = jq_truncate_value_desc(type_name(other), other_json)

              throw(
                {:eval_error, "string (#{inspect(str_so_far)}) and #{other_desc} cannot be added"}
              )
          end

        new_acc = if has_prev, do: [acc, sep, str], else: [str]
        {new_acc, true}
      end)

    IO.iodata_to_binary(elem(result, 0))
  end

  defp do_eval_func(:ascii_downcase, [], data, _opts, _eval) when is_binary(data) do
    data
    |> String.to_charlist()
    |> Enum.map(fn c -> if c >= ?A and c <= ?Z, do: c + 32, else: c end)
    |> List.to_string()
  end

  defp do_eval_func(:ascii_upcase, [], data, _opts, _eval) when is_binary(data) do
    data
    |> String.to_charlist()
    |> Enum.map(fn c -> if c >= ?a and c <= ?z, do: c - 32, else: c end)
    |> List.to_string()
  end

  defp do_eval_func(:ltrimstr, [prefix_expr], data, opts, eval) when is_binary(data) do
    prefix = eval.eval(prefix_expr, data, opts)

    unless is_binary(prefix) do
      throw({:eval_error, "startswith() requires string inputs"})
    end

    if String.starts_with?(data, prefix) do
      String.replace_prefix(data, prefix, "")
    else
      data
    end
  end

  defp do_eval_func(:ltrimstr, [_prefix_expr], _data, _opts, _eval) do
    throw({:eval_error, "startswith() requires string inputs"})
  end

  defp do_eval_func(:rtrimstr, [suffix_expr], data, opts, eval) when is_binary(data) do
    suffix = eval.eval(suffix_expr, data, opts)

    unless is_binary(suffix) do
      throw({:eval_error, "endswith() requires string inputs"})
    end

    if String.ends_with?(data, suffix) do
      String.replace_suffix(data, suffix, "")
    else
      data
    end
  end

  defp do_eval_func(:rtrimstr, [_suffix_expr], _data, _opts, _eval) do
    throw({:eval_error, "endswith() requires string inputs"})
  end

  defp do_eval_func(:startswith, [prefix_expr], data, opts, eval) when is_binary(data) do
    prefix = eval.eval(prefix_expr, data, opts)
    String.starts_with?(data, prefix)
  end

  defp do_eval_func(:endswith, [suffix_expr], data, opts, eval) when is_binary(data) do
    suffix = eval.eval(suffix_expr, data, opts)
    String.ends_with?(data, suffix)
  end

  # trim, ltrim, rtrim — 0-arg forms (trim whitespace)
  defp do_eval_func(:trim, [], data, _opts, _eval) when is_binary(data), do: String.trim(data)

  defp do_eval_func(:trim, [], _data, _opts, _eval),
    do: throw({:eval_error, "trim input must be a string"})

  defp do_eval_func(:ltrim, [], data, _opts, _eval) when is_binary(data),
    do: String.trim_leading(data)

  defp do_eval_func(:ltrim, [], _data, _opts, _eval),
    do: throw({:eval_error, "trim input must be a string"})

  defp do_eval_func(:rtrim, [], data, _opts, _eval) when is_binary(data),
    do: String.trim_trailing(data)

  defp do_eval_func(:rtrim, [], _data, _opts, _eval),
    do: throw({:eval_error, "trim input must be a string"})

  # trimstr is not a standard jq function — ltrimstr/rtrimstr are. But just in case:
  defp do_eval_func(:trimstr, [s_expr], data, opts, eval) when is_binary(data) do
    s = eval.eval(s_expr, data, opts)

    if s == "" do
      data
    else
      data |> String.trim_leading(s) |> String.trim_trailing(s)
    end
  end

  defp do_eval_func(:implode, [], data, _opts, _eval) when is_list(data) do
    # U+FFFD replacement character for invalid codepoints
    replacement = <<0xFFFD::utf8>>

    Enum.map_join(data, fn
      :nan ->
        # NaN is serialized as null in jq
        throw(
          {:eval_error, "number (null) can't be imploded, unicode codepoint needs to be numeric"}
        )

      n when is_float(n) ->
        # Floats are truncated to integer first
        implode_codepoint(trunc(n), replacement)

      n when is_integer(n) ->
        implode_codepoint(n, replacement)

      other ->
        json_str = Jason.encode!(other)
        type_str = type_name(other)
        truncated = jq_truncate_value_for_implode(type_str, json_str)

        throw(
          {:eval_error, "#{truncated} can't be imploded, unicode codepoint needs to be numeric"}
        )
    end)
  end

  defp do_eval_func(:implode, [], _data, _opts, _eval) do
    throw({:eval_error, "implode input must be an array"})
  end

  defp do_eval_func(:explode, [], data, _opts, _eval) when is_binary(data) do
    String.to_charlist(data)
  end

  # Type conversion functions
  defp do_eval_func(:tostring, [], :nan, _opts, _eval), do: "null"

  defp do_eval_func(:tostring, [], data, _opts, _eval) do
    cond do
      is_binary(data) -> data
      is_nil(data) -> "null"
      is_boolean(data) -> to_string(data)
      is_number(data) -> number_to_jq_string(data)
      true -> Jason.encode!(data)
    end
  end

  defp do_eval_func(:tonumber, [], data, _opts, _eval) when is_number(data), do: data

  defp do_eval_func(:tonumber, [], data, _opts, _eval) when is_binary(data) do
    # Elixir's Float.parse doesn't handle leading "." — normalize to "0."
    normalized =
      cond do
        String.starts_with?(data, ".") -> "0" <> data
        String.starts_with?(data, "-.") -> "-0" <> String.slice(data, 1..-1//1)
        true -> data
      end

    case Float.parse(normalized) do
      {n, ""} -> if n == trunc(n), do: trunc(n), else: n
      _ -> throw({:eval_error, "cannot parse number: #{data}"})
    end
  end

  defp do_eval_func(:tojson, [], :nan, _opts, _eval), do: "null"

  defp do_eval_func(:tojson, [], data, _opts, _eval) do
    sanitized = sanitize_nan(data)
    json = encode_json_with_depth_limit(sanitized, @tojson_depth_limit)
    # jq outputs e+NNN for positive exponents; Elixir/Jason omits the +
    normalize_json_exponents(json)
  end

  defp do_eval_func(:fromjson, [], data, _opts, _eval) when is_binary(data) do
    case data do
      s when s in ["nan", "NaN", "-NaN"] ->
        :nan

      s ->
        # Check for NaN with payload (e.g., "NaN1", "NaN100")
        if String.starts_with?(s, "NaN") and byte_size(s) > 3 do
          col = byte_size(s)

          throw(
            {:eval_error,
             "Invalid numeric literal at EOF at line 1, column #{col} (while parsing '#{s}')"}
          )
        else
          # Check depth limit before parsing (jq limits to 10000)
          if json_exceeds_depth?(s, 10_000) do
            throw({:eval_error, "Exceeds depth limit for parsing"})
          end

          case Jason.decode(s) do
            {:ok, result} -> result
            {:error, _} -> throw({:eval_error, json_parse_error_message(s)})
          end
        end
    end
  end

  defp do_eval_func(:ascii, [], data, _opts, _eval) when is_number(data) do
    <<data::utf8>>
  end

  # Logic functions
  defp do_eval_func(:not, [], data, _opts, _eval), do: not truthy?(data)

  defp do_eval_func(:error, [msg_expr], data, opts, eval) do
    msg = eval.eval(msg_expr, data, opts)

    if is_binary(msg) do
      throw({:eval_error, msg})
    else
      throw({:eval_error_value, msg})
    end
  end

  defp do_eval_func(:error, [], data, _opts, _eval) do
    if is_binary(data) do
      throw({:eval_error, data})
    else
      throw({:eval_error_value, data})
    end
  end

  # Math functions
  defp do_eval_func(:floor, [], :nan, _opts, _eval), do: :nan
  defp do_eval_func(:floor, [], data, _opts, _eval) when is_number(data), do: floor(data)
  defp do_eval_func(:ceil, [], :nan, _opts, _eval), do: :nan
  defp do_eval_func(:ceil, [], data, _opts, _eval) when is_number(data), do: ceil(data)
  defp do_eval_func(:round, [], :nan, _opts, _eval), do: :nan
  defp do_eval_func(:round, [], data, _opts, _eval) when is_number(data), do: round(data)
  defp do_eval_func(:fabs, [], :nan, _opts, _eval), do: :nan
  defp do_eval_func(:fabs, [], data, _opts, _eval) when is_number(data), do: abs(data) * 1.0
  defp do_eval_func(:abs, [], :nan, _opts, _eval), do: :nan
  defp do_eval_func(:abs, [], data, _opts, _eval) when is_number(data), do: abs(data)
  defp do_eval_func(:abs, [], nil, _opts, _eval), do: nil
  defp do_eval_func(:abs, [], data, _opts, _eval) when is_binary(data), do: data
  defp do_eval_func(:abs, [], data, _opts, _eval) when is_boolean(data), do: data
  defp do_eval_func(:abs, [], data, _opts, _eval) when is_map(data), do: data
  defp do_eval_func(:sqrt, [], data, _opts, _eval) when is_number(data), do: :math.sqrt(data)

  defp do_eval_func(:pow, [base_expr, exp_expr], data, opts, eval) do
    base = eval.eval(base_expr, data, opts)
    exp = eval.eval(exp_expr, data, opts)
    result = :math.pow(base, exp)
    if result == trunc(result), do: trunc(result), else: result
  end

  defp do_eval_func(:log2, [], data, _opts, _eval) when is_number(data) do
    :math.log2(data)
  end

  defp do_eval_func(:log, [], data, _opts, _eval) when is_number(data) do
    :math.log(data)
  end

  defp do_eval_func(:exp, [], data, _opts, _eval) when is_number(data) do
    :math.exp(data)
  end

  defp do_eval_func(:exp2, [], data, _opts, _eval) when is_number(data) do
    :math.pow(2, data)
  end

  defp do_eval_func(:exp10, [], data, _opts, _eval) when is_number(data) do
    :math.pow(10, data)
  end

  defp do_eval_func(:log10, [], data, _opts, _eval) when is_number(data) do
    :math.log10(data)
  end

  defp do_eval_func(:sin, [], data, _opts, _eval) when is_number(data), do: :math.sin(data)
  defp do_eval_func(:cos, [], data, _opts, _eval) when is_number(data), do: :math.cos(data)
  defp do_eval_func(:tan, [], data, _opts, _eval) when is_number(data), do: :math.tan(data)
  defp do_eval_func(:asin, [], data, _opts, _eval) when is_number(data), do: :math.asin(data)
  defp do_eval_func(:acos, [], data, _opts, _eval) when is_number(data), do: :math.acos(data)
  defp do_eval_func(:atan, [], data, _opts, _eval) when is_number(data), do: :math.atan(data)

  defp do_eval_func(:atan2, [y_expr, x_expr], data, opts, eval) do
    y = eval.eval(y_expr, data, opts)
    x = eval.eval(x_expr, data, opts)
    :math.atan2(y, x)
  end

  defp do_eval_func(:significand, [], data, _opts, _eval) when is_number(data) do
    if data == 0, do: 0.0, else: data / :math.pow(2, Float.floor(:math.log2(abs(data))))
  end

  defp do_eval_func(:exponent, [], data, _opts, _eval) when is_number(data) do
    if data == 0, do: 0, else: Float.floor(:math.log2(abs(data))) |> trunc()
  end

  # Path functions
  defp do_eval_func(:getpath, [path_expr], data, opts, eval) do
    path = eval.eval(path_expr, data, opts)
    get_path(data, path)
  end

  defp do_eval_func(:paths, [], data, _opts, _eval), do: {:multi, get_all_paths(data, [])}

  defp do_eval_func(:paths, [filter_expr], data, opts, eval) do
    all_paths = get_all_paths(data, [])

    matching =
      Enum.filter(all_paths, fn path ->
        val = get_path(data, path)
        result = eval.eval(filter_expr, val, opts)
        truthy?(result)
      end)

    {:multi, matching}
  end

  defp do_eval_func(:leaf_paths, [], data, _opts, _eval) do
    paths = get_all_paths(data, [])

    leaf_paths =
      Enum.filter(paths, fn path ->
        val = get_path(data, path)
        not is_map(val) and not is_list(val)
      end)

    {:multi, leaf_paths}
  end

  defp do_eval_func(:path, [expr], data, opts, eval) do
    paths = get_expr_paths_strict(expr, data, opts, eval)
    {:multi, paths}
  end

  defp do_eval_func(:setpath, [path_expr, value_expr], data, opts, eval) do
    path = eval.eval(path_expr, data, opts)
    value = eval.eval(value_expr, data, opts)

    # Validate: integer key on an object (not nil) is an error
    case path do
      [idx | _] when is_integer(idx) and is_map(data) ->
        throw({:eval_error, "Cannot index object with number"})

      _ ->
        :ok
    end

    set_path(data, path, value)
  end

  defp do_eval_func(:delpaths, [paths_expr], data, opts, eval) do
    paths = eval.eval(paths_expr, data, opts)

    unless is_list(paths) do
      throw({:eval_error, "Paths must be specified as an array"})
    end

    # Sort paths in reverse to avoid index shifting issues
    sorted_paths =
      paths
      |> Enum.sort_by(fn p -> {length(p), p} end, :desc)

    Enum.reduce(sorted_paths, data, &delete_path(&2, &1))
  end

  # Entry functions
  defp do_eval_func(:to_entries, [], data, _opts, _eval) when is_map(data) do
    data
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> %{"key" => k, "value" => v} end)
  end

  defp do_eval_func(:from_entries, [], data, _opts, _eval) when is_list(data) do
    Enum.reduce(data, %{}, fn entry, acc ->
      key =
        Map.get(entry, "key") ||
          Map.get(entry, "Key") ||
          Map.get(entry, "k") ||
          Map.get(entry, "name") ||
          Map.get(entry, "Name")

      value =
        cond do
          Map.has_key?(entry, "value") -> Map.get(entry, "value")
          Map.has_key?(entry, "Value") -> Map.get(entry, "Value")
          Map.has_key?(entry, "v") -> Map.get(entry, "v")
          true -> nil
        end

      if key != nil, do: Map.put(acc, to_string(key), value), else: acc
    end)
  end

  defp do_eval_func(:with_entries, [expr], data, opts, eval) when is_map(data) do
    entries =
      data
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> %{"key" => k, "value" => v} end)

    transformed =
      Enum.flat_map(entries, fn entry ->
        case eval.eval(expr, entry, opts) do
          {:multi, items} -> items
          :empty -> []
          item -> [item]
        end
      end)

    Enum.reduce(transformed, %{}, fn entry, acc ->
      key = Map.get(entry, "key") || Map.get(entry, "k") || Map.get(entry, "name")
      value = Map.get(entry, "value", Map.get(entry, "v"))
      if key != nil, do: Map.put(acc, to_string(key), value), else: acc
    end)
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

  # Time functions
  defp do_eval_func(:strftime, [fmt_expr], data, opts, eval) when is_number(data) do
    fmt = eval.eval(fmt_expr, data, opts)

    case fmt do
      {:multi, fmts} ->
        results =
          Enum.map(fmts, fn f ->
            dt = DateTime.from_unix!(trunc(data))
            Calendar.strftime(dt, f)
          end)

        {:multi, results}

      f when is_binary(f) ->
        dt = DateTime.from_unix!(trunc(data))
        Calendar.strftime(dt, f)

      _ ->
        throw({:eval_error, "strftime/1 requires a string format"})
    end
  end

  defp do_eval_func(:strftime, [fmt_expr], data, opts, eval) when is_list(data) do
    # Validate that all elements are numeric
    unless Enum.all?(data, &is_number/1) do
      throw({:eval_error, "strftime/1 requires parsed datetime inputs"})
    end

    # Pad short arrays to at least 8 elements
    data = data ++ List.duplicate(0, max(0, 8 - length(data)))

    do_eval_func(:strflocaltime, [fmt_expr], data, opts, eval)
  end

  defp do_eval_func(:strftime, [_fmt_expr], _data, _opts, _eval) do
    throw({:eval_error, "strftime/1 requires numeric input"})
  end

  defp do_eval_func(:strptime, [fmt_expr], data, opts, eval) when is_binary(data) do
    fmt = eval.eval(fmt_expr, data, opts)

    # Parse ISO 8601 dates — this is the most common format in tests
    case parse_datetime_string(data, fmt) do
      {:ok, dt} ->
        # Return broken-down time array: [year, mon(0-based), mday, hour, min, sec, wday, yday]
        wday = Date.day_of_week(DateTime.to_date(dt)) |> rem(7)
        yday = Date.diff(DateTime.to_date(dt), Date.new!(dt.year, 1, 1))

        [
          dt.year,
          dt.month - 1,
          dt.day,
          dt.hour,
          dt.minute,
          dt.second,
          wday,
          yday
        ]

      :error ->
        throw(
          {:eval_error, "strptime: cannot parse #{inspect(data)} with format #{inspect(fmt)}"}
        )
    end
  end

  defp do_eval_func(:gmtime, [], data, _opts, _eval) when is_number(data) do
    dt = DateTime.from_unix!(trunc(data))
    wday = Date.day_of_week(DateTime.to_date(dt)) |> rem(7)
    yday = Date.diff(DateTime.to_date(dt), Date.new!(dt.year, 1, 1))

    [
      dt.year,
      dt.month - 1,
      dt.day,
      dt.hour,
      dt.minute,
      dt.second,
      wday,
      yday
    ]
  end

  defp do_eval_func(:mktime, [], data, _opts, _eval) when is_list(data) do
    unless Enum.all?(data, &is_number/1) do
      throw({:eval_error, "mktime requires parsed datetime inputs"})
    end

    # Pad short arrays to at least 8 elements
    data = data ++ List.duplicate(0, max(0, 8 - length(data)))

    # Broken down time: [year, month(0-based), mday, hour, min, sec, ...]
    [year, mon, day, hour, min, sec | _] = data

    try do
      case NaiveDateTime.new(year, mon + 1, day, hour, min, sec) do
        {:ok, ndt} ->
          case DateTime.from_naive(ndt, "Etc/UTC") do
            {:ok, dt} -> DateTime.to_unix(dt)
            _ -> 0
          end

        _ ->
          0
      end
    rescue
      _ -> 0
    end
  end

  defp do_eval_func(:mktime, [], _data, _opts, _eval) do
    throw({:eval_error, "mktime requires array input"})
  end

  defp do_eval_func(:todate, [], data, _opts, _eval) when is_number(data) do
    dt = DateTime.from_unix!(trunc(data))
    Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%SZ")
  end

  defp do_eval_func(:fromdate, [], data, _opts, _eval) when is_binary(data) do
    case DateTime.from_iso8601(data) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> throw({:eval_error, "cannot parse date: #{data}"})
    end
  end

  defp do_eval_func(:date, [], data, _opts, _eval) when is_number(data) do
    dt = DateTime.from_unix!(trunc(data))
    Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%SZ")
  end

  defp do_eval_func(:dateadd, [unit_expr, n_expr], data, opts, eval) when is_number(data) do
    _unit = eval.eval(unit_expr, data, opts)
    n = eval.eval(n_expr, data, opts)
    data + n
  end

  defp do_eval_func(:datesub, [unit_expr, n_expr], data, opts, eval) when is_number(data) do
    _unit = eval.eval(unit_expr, data, opts)
    n = eval.eval(n_expr, data, opts)
    data - n
  end

  defp do_eval_func(:strflocaltime, [fmt_expr], data, opts, eval) when is_list(data) do
    fmt = eval.eval(fmt_expr, data, opts)

    case fmt do
      {:multi, fmts} ->
        results =
          Enum.map(fmts, fn f ->
            do_strflocaltime_format(data, f)
          end)

        {:multi, results}

      f when is_binary(f) ->
        do_strflocaltime_format(data, f)

      _ ->
        throw({:eval_error, "strflocaltime/1 requires a string format"})
    end
  end

  defp do_eval_func(:strflocaltime, [fmt_expr], data, opts, eval) when is_number(data) do
    # Convert number (unix timestamp) to broken-down time via gmtime, then format
    broken = do_eval_func(:gmtime, [], data, opts, eval)
    do_eval_func(:strflocaltime, [fmt_expr], broken, opts, eval)
  end

  defp do_eval_func(:strflocaltime, [_fmt_expr], _data, _opts, _eval) do
    throw({:eval_error, "strflocaltime/1 requires a string format"})
  end

  # Predicate functions
  defp do_eval_func(:any, [], data, _opts, _eval) when is_list(data) do
    Enum.any?(data, &truthy?/1)
  end

  defp do_eval_func(:any, [expr], data, opts, eval) when is_list(data) do
    Enum.any?(data, fn item -> truthy?(eval.eval(expr, item, opts)) end)
  end

  # any(gen; cond) - 2-arg form with generator
  # any short-circuits: if any value is truthy, it returns true immediately
  # and ignores subsequent errors
  defp do_eval_func(:any, [gen_expr, cond_expr], data, opts, eval) do
    case eval.eval_generator_take(gen_expr, data, opts, :all) do
      {:ok, results} ->
        results = Enum.reject(results, &(&1 == :empty))
        Enum.any?(results, fn item -> truthy?(eval.eval(cond_expr, item, opts)) end)

      {:error, reason, results} ->
        results = Enum.reject(results, &(&1 == :empty))
        # If we found a truthy value before the error, return true
        if Enum.any?(results, fn item -> truthy?(eval.eval(cond_expr, item, opts)) end) do
          true
        else
          throw({:eval_error, reason})
        end
    end
  end

  defp do_eval_func(:all, [], data, _opts, _eval) when is_list(data) do
    Enum.all?(data, &truthy?/1)
  end

  defp do_eval_func(:all, [expr], data, opts, eval) when is_list(data) do
    Enum.all?(data, fn item -> truthy?(eval.eval(expr, item, opts)) end)
  end

  # all(gen; cond) - 2-arg form with generator
  # all short-circuits: if any value is falsy, it returns false immediately
  # and ignores subsequent errors
  defp do_eval_func(:all, [gen_expr, cond_expr], data, opts, eval) do
    case eval.eval_generator_take(gen_expr, data, opts, :all) do
      {:ok, results} ->
        results = Enum.reject(results, &(&1 == :empty))
        Enum.all?(results, fn item -> truthy?(eval.eval(cond_expr, item, opts)) end)

      {:error, reason, results} ->
        results = Enum.reject(results, &(&1 == :empty))
        # If we found a falsy value before the error, return false
        if Enum.all?(results, fn item -> truthy?(eval.eval(cond_expr, item, opts)) end) do
          throw({:eval_error, reason})
        else
          false
        end
    end
  end

  # Range functions
  defp do_eval_func(:range, [n_expr], data, opts, eval) do
    case eval.eval(n_expr, data, opts) do
      {:multi, ns} ->
        results =
          Enum.flat_map(ns, fn n ->
            n = trunc(n)
            if n <= 0, do: [], else: Enum.to_list(0..(n - 1))
          end)

        {:multi, results}

      :empty ->
        :empty

      n ->
        n = trunc(n)
        if n <= 0, do: {:multi, []}, else: {:multi, Enum.to_list(0..(n - 1))}
    end
  end

  defp do_eval_func(:range, [from_expr, to_expr], data, opts, eval) do
    from_val = eval.eval(from_expr, data, opts)
    to_val = eval.eval(to_expr, data, opts)

    froms =
      case from_val do
        {:multi, items} -> items
        :empty -> []
        v -> [v]
      end

    tos =
      case to_val do
        {:multi, items} -> items
        :empty -> []
        v -> [v]
      end

    results =
      Enum.flat_map(froms, fn from ->
        Enum.flat_map(tos, fn to ->
          from = if is_float(from), do: trunc(from), else: from
          to = if is_float(to), do: trunc(to), else: to

          if from >= to do
            []
          else
            Enum.to_list(from..(to - 1))
          end
        end)
      end)

    {:multi, results}
  end

  defp do_eval_func(:range, [from_expr, to_expr, step_expr], data, opts, eval) do
    from = eval.eval(from_expr, data, opts)
    to = eval.eval(to_expr, data, opts)
    step = eval.eval(step_expr, data, opts)

    cond do
      step == 0 ->
        {:multi, []}

      step > 0 and from >= to ->
        {:multi, []}

      step < 0 and from <= to ->
        {:multi, []}

      true ->
        # Generate range manually to handle float step
        {:multi, generate_range(from, to, step, [])}
    end
  end

  # Iteration functions
  defp do_eval_func(:limit, [n_expr, expr], data, opts, eval) do
    n = eval.eval(n_expr, data, opts)

    # Handle multi-value n: limit(5,7; gen) → limit(5;gen), limit(7;gen)
    case n do
      {:multi, ns} ->
        all_results =
          Enum.flat_map(ns, fn ni ->
            {:multi, res} = do_eval_func(:limit, [{:literal, ni}, expr], data, opts, eval)
            res
          end)

        {:multi, all_results}

      _ ->
        if is_number(n) and n < 0 do
          throw({:eval_error, "limit doesn't support negative count"})
        end

        n = if is_number(n), do: trunc(n), else: n

        case eval.eval_generator_take(expr, data, opts, n) do
          {:ok, results} ->
            results = Enum.reject(results, &(&1 == :empty))
            {:multi, Enum.take(results, n)}

          {:error, _reason, results} ->
            results = Enum.reject(results, &(&1 == :empty))

            if length(results) >= n do
              {:multi, Enum.take(results, n)}
            else
              {:multi, results}
            end
        end
    end
  end

  defp do_eval_func(:until, [cond_expr, update_expr], data, opts, eval) do
    do_until(data, cond_expr, update_expr, opts, eval, 0)
  end

  defp do_eval_func(:while, [cond_expr, update_expr], data, opts, eval) do
    do_while(data, cond_expr, update_expr, opts, eval, [])
  end

  defp do_eval_func(:repeat, [expr], data, opts, eval) do
    do_repeat(data, expr, opts, eval, [], 0)
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

    if is_list(s) do
      # Find indices where the subsequence s appears
      find_subarray_indices(data, s, 0, [])
    else
      data
      |> Enum.with_index()
      |> Enum.filter(fn {item, _} -> item == s end)
      |> Enum.map(fn {_, i} -> i end)
    end
  end

  defp do_eval_func(:index, [s_expr], data, opts, eval) when is_binary(data) do
    s = eval.eval(s_expr, data, opts)

    cond do
      not is_binary(s) ->
        nil

      s == "" and data == "" ->
        nil

      s == "" ->
        0

      true ->
        # Use codepoint-based index lookup
        indices = find_string_indices(data, s, 0, [])

        case indices do
          [first | _] -> first
          [] -> nil
        end
    end
  end

  defp do_eval_func(:index, [s_expr], data, opts, eval) when is_list(data) do
    s = eval.eval(s_expr, data, opts)

    if is_list(s) do
      case find_subarray_indices(data, s, 0, []) do
        [first | _] -> first
        [] -> nil
      end
    else
      Enum.find_index(data, &(&1 == s))
    end
  end

  defp do_eval_func(:rindex, [s_expr], data, opts, eval) when is_binary(data) do
    s = eval.eval(s_expr, data, opts)
    indices = find_string_indices(data, s, 0, [])
    List.last(indices)
  end

  defp do_eval_func(:rindex, [s_expr], data, opts, eval) when is_list(data) do
    s = eval.eval(s_expr, data, opts)

    if is_list(s) do
      case find_subarray_indices(data, s, 0, []) do
        [] -> nil
        indices -> List.last(indices)
      end
    else
      data
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {item, i} -> if item == s, do: i end)
    end
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
      {:ok, regex} -> Regex.replace(regex, data, fn _, _ -> replacement end)
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  defp do_eval_func(:gsub, [regex_expr, repl_expr, flags_expr], data, opts, eval)
       when is_binary(data) do
    pattern = eval.eval(regex_expr, data, opts)
    replacement = eval.eval(repl_expr, data, opts)
    flags = eval.eval(flags_expr, data, opts)
    regex_opts = parse_regex_flags(flags)

    case Regex.compile(pattern, regex_opts) do
      {:ok, regex} -> Regex.replace(regex, data, fn _, _ -> replacement end)
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  defp do_eval_func(:sub, [regex_expr, repl_expr], data, opts, eval) when is_binary(data) do
    pattern = eval.eval(regex_expr, data, opts)
    replacement = eval.eval(repl_expr, data, opts)

    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.replace(regex, data, fn _, _ -> replacement end, global: false)
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

  defp do_eval_func(:splits, [regex_expr, flags_expr], data, opts, eval) when is_binary(data) do
    pattern = eval.eval(regex_expr, data, opts)
    flags = eval.eval(flags_expr, data, opts)
    regex_opts = parse_regex_flags(flags)

    case Regex.compile(pattern, regex_opts) do
      {:ok, regex} -> {:multi, Regex.split(regex, data)}
      {:error, _} -> throw({:eval_error, "invalid regex: #{pattern}"})
    end
  end

  # Type filter functions
  defp do_eval_func(:numbers, [], :nan, _opts, _eval), do: :nan
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
  defp do_eval_func(:infinite, [], _data, _opts, _eval), do: 1.7_976_931_348_623_157e308
  defp do_eval_func(:nan, [], _data, _opts, _eval), do: :nan

  # have_decnum — we don't have decimal number support
  defp do_eval_func(:have_decnum, [], _data, _opts, _eval), do: false

  # modulemeta
  defp do_eval_func(:modulemeta, [], data, opts, _eval) when is_binary(data) do
    Evaluator.get_module_meta(data, opts)
  end

  # Meta functions
  defp do_eval_func(:builtins, [], _data, _opts, _eval), do: builtins_list()

  defp do_eval_func(:debug, [], data, _opts, _eval), do: data

  defp do_eval_func(:debug, [msg_expr], data, opts, eval) do
    _msg = eval.eval(msg_expr, data, opts)
    data
  end

  defp do_eval_func(:input, [], _data, _opts, _eval) do
    throw({:eval_error, "break"})
  end

  defp do_eval_func(:inputs, [], _data, _opts, _eval), do: {:multi, []}

  # toboolean — converts values to boolean
  defp do_eval_func(:toboolean, [], true, _opts, _eval), do: true
  defp do_eval_func(:toboolean, [], false, _opts, _eval), do: false

  defp do_eval_func(:toboolean, [], data, _opts, _eval) when is_binary(data) do
    case data do
      "true" ->
        true

      "false" ->
        false

      _ ->
        throw({:eval_error, "string (#{inspect(data)}) cannot be parsed as a boolean"})
    end
  end

  defp do_eval_func(:toboolean, [], data, _opts, _eval) do
    desc = jq_value_desc(data)
    throw({:eval_error, "#{desc} cannot be parsed as a boolean"})
  end

  # getpath/setpath with list
  defp do_eval_func(:ascii, [], data, _opts, _eval) when is_binary(data) do
    String.valid?(data) and data == String.replace(data, ~r/[^\x00-\x7F]/, "")
  end

  defp do_eval_func(name, _args, _data, _opts, _eval) do
    throw({:eval_error, "unknown function: #{name}"})
  end

  # Helper functions

  # Valid Unicode codepoint that is not a surrogate
  defp implode_codepoint(n, _replacement)
       when n >= 0 and n <= 0x10FFFF and not (n >= 0xD800 and n <= 0xDFFF) do
    <<n::utf8>>
  end

  # Invalid codepoint: negative, surrogate, or > U+10FFFF
  defp implode_codepoint(_n, replacement), do: replacement

  defp do_strflocaltime_format(data, fmt) when is_list(data) and is_binary(fmt) do
    unless Enum.all?(data, &is_number/1) do
      throw({:eval_error, "strflocaltime/1 requires parsed datetime inputs"})
    end

    padded = data ++ List.duplicate(0, max(0, 8 - length(data)))
    [year, mon, day, hour, min, sec | _] = padded

    try do
      case NaiveDateTime.new(
             trunc(year),
             trunc(mon) + 1,
             trunc(day),
             trunc(hour),
             trunc(min),
             trunc(sec)
           ) do
        {:ok, ndt} ->
          Calendar.strftime(ndt, fmt)

        _ ->
          ""
      end
    rescue
      _ -> ""
    end
  end

  defp add_values([]), do: nil

  defp add_values([first | rest]) when is_binary(first) do
    # Use IOData for O(n) string concatenation
    result =
      Enum.reduce(rest, [first], fn item, acc ->
        cond do
          is_binary(item) -> [acc, item]
          is_nil(item) -> acc
          true -> throw({:eval_error, "cannot add"})
        end
      end)

    IO.iodata_to_binary(result)
  end

  defp add_values([first | rest]) do
    Enum.reduce(rest, first, fn item, acc ->
      cond do
        is_number(acc) and is_number(item) -> acc + item
        is_list(acc) and is_list(item) -> acc ++ item
        is_map(acc) and is_map(item) -> Map.merge(acc, item)
        is_nil(acc) -> item
        is_nil(item) -> acc
        true -> throw({:eval_error, "cannot add"})
      end
    end)
  end

  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true

  # jq-style value description for error messages
  defp jq_value_desc(:nan), do: "number (null)"
  defp jq_value_desc(nil), do: "null (null)"
  defp jq_value_desc(v) when is_boolean(v), do: "boolean (#{v})"
  defp jq_value_desc(v) when is_number(v), do: "number (#{v})"
  defp jq_value_desc(v) when is_binary(v), do: "string (#{inspect(v)})"
  defp jq_value_desc(v) when is_list(v), do: "array (#{Jason.encode!(v)})"
  defp jq_value_desc(v) when is_map(v), do: "object (#{Jason.encode!(v)})"

  defp type_name(:nan), do: "number"
  defp type_name(nil), do: "null"
  defp type_name(x) when is_boolean(x), do: "boolean"
  defp type_name(x) when is_number(x), do: "number"
  defp type_name(x) when is_binary(x), do: "string"
  defp type_name(x) when is_list(x), do: "array"
  defp type_name(x) when is_map(x), do: "object"

  # Truncate value description for error messages (jq truncates at ~10 bytes)
  defp jq_truncate_value_desc(type_str, json_str) do
    if byte_size(json_str) > 14 do
      truncated = String.slice(json_str, 0, 11)
      "#{type_str} (#{truncated}...)"
    else
      "#{type_str} (#{json_str})"
    end
  end

  defp jq_truncate_value_for_implode(type_str, json_str) do
    "#{type_str} (#{json_str})"
  end

  defp deep_flatten(list) when is_list(list) do
    Enum.flat_map(list, fn
      item when is_list(item) -> deep_flatten(item)
      item -> [item]
    end)
  end

  defp flatten_to_depth(list, 0), do: list

  defp flatten_to_depth(list, depth) when depth > 0 do
    Enum.flat_map(list, fn
      item when is_list(item) -> flatten_to_depth(item, depth - 1)
      item -> [item]
    end)
  end

  # jq comparison for sort
  defp jq_less_or_equal?(a, b) do
    jq_type_order(a) < jq_type_order(b) or
      (jq_type_order(a) == jq_type_order(b) and jq_value_lte?(a, b))
  end

  defp jq_type_order(:nan), do: 3
  defp jq_type_order(nil), do: 0
  defp jq_type_order(false), do: 1
  defp jq_type_order(true), do: 2
  defp jq_type_order(n) when is_number(n), do: 3
  defp jq_type_order(s) when is_binary(s), do: 4
  defp jq_type_order(l) when is_list(l), do: 5
  defp jq_type_order(m) when is_map(m), do: 6

  defp jq_value_lte?(a, b) when is_number(a) and is_number(b), do: a <= b
  defp jq_value_lte?(a, b) when is_binary(a) and is_binary(b), do: a <= b

  defp jq_value_lte?(a, b) when is_list(a) and is_list(b) do
    Enum.zip(a, b)
    |> Enum.reduce_while(:eq, fn {x, y}, _ ->
      cond do
        jq_less_or_equal?(x, y) and not jq_less_or_equal?(y, x) -> {:halt, :lt}
        jq_less_or_equal?(y, x) and not jq_less_or_equal?(x, y) -> {:halt, :gt}
        true -> {:cont, :eq}
      end
    end)
    |> case do
      :lt -> true
      :gt -> false
      :eq -> length(a) <= length(b)
    end
  end

  defp jq_value_lte?(a, b) when is_map(a) and is_map(b) do
    size_a = map_size(a)
    size_b = map_size(b)

    cond do
      size_a < size_b ->
        true

      size_a > size_b ->
        false

      true ->
        # Same number of keys: compare by sorted keys, then by values
        keys_a = Map.keys(a) |> Enum.sort()
        keys_b = Map.keys(b) |> Enum.sort()

        case compare_lists(keys_a, keys_b) do
          :lt ->
            true

          :gt ->
            false

          :eq ->
            vals_a = Enum.map(keys_a, &Map.get(a, &1))
            vals_b = Enum.map(keys_b, &Map.get(b, &1))
            compare_lists(vals_a, vals_b) != :gt
        end
    end
  end

  defp jq_value_lte?(_, _), do: true

  defp compare_lists([], []), do: :eq
  defp compare_lists([], _), do: :lt
  defp compare_lists(_, []), do: :gt

  defp compare_lists([x | xs], [y | ys]) do
    cond do
      jq_less_or_equal?(x, y) and not jq_less_or_equal?(y, x) -> :lt
      jq_less_or_equal?(y, x) and not jq_less_or_equal?(x, y) -> :gt
      true -> compare_lists(xs, ys)
    end
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
    Enum.flat_map(Enum.sort(Map.to_list(data)), fn {k, v} ->
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
    existing = Map.get(data, key)
    Map.put(data, key, set_path(existing, rest, value))
  end

  defp set_path(data, [idx | rest], value) when is_list(data) and is_integer(idx) do
    idx = if idx < 0, do: length(data) + idx, else: idx

    if idx < 0, do: throw({:eval_error, "Out of bounds negative array index"})

    if is_integer(idx) and idx > 100_000 do
      throw({:eval_error, "Array index too large"})
    end

    data =
      if idx >= length(data), do: data ++ List.duplicate(nil, idx + 1 - length(data)), else: data

    List.update_at(data, idx, fn existing -> set_path(existing, rest, value) end)
  end

  # When data is nil, create the appropriate structure
  defp set_path(nil, [key | rest], value) when is_binary(key) do
    %{key => set_path(nil, rest, value)}
  end

  defp set_path(nil, [idx | rest], value) when is_integer(idx) do
    if idx < 0, do: throw({:eval_error, "Out of bounds negative array index"})
    if idx > 100_000, do: throw({:eval_error, "Array index too large"})
    list = List.duplicate(nil, idx + 1)
    List.update_at(list, idx, fn _ -> set_path(nil, rest, value) end)
  end

  # Type mismatch errors — when data type conflicts with key type
  defp set_path(data, [key | _rest], _value)
       when is_number(data) and is_binary(key) do
    throw({:eval_error, "Cannot index number with string #{Jason.encode!(key)}"})
  end

  defp set_path(data, [idx | _rest], _value)
       when is_number(data) and is_integer(idx) do
    throw({:eval_error, "Cannot index number with number"})
  end

  defp set_path(data, [idx | _rest], _value)
       when is_map(data) and is_integer(idx) do
    throw({:eval_error, "Cannot index object with number"})
  end

  defp set_path(data, [key | rest], value)
       when is_binary(key) and not is_map(data) do
    # For non-nil, non-map, non-number: create structure (e.g., boolean, string -> replace)
    %{key => set_path(nil, rest, value)}
  end

  defp set_path(data, [idx | rest], value)
       when is_integer(idx) and not is_list(data) do
    # For non-nil, non-list, non-map, non-number: create structure
    if idx < 0, do: throw({:eval_error, "Out of bounds negative array index"})
    if idx > 100_000, do: throw({:eval_error, "Array index too large"})
    list = List.duplicate(nil, idx + 1)
    List.update_at(list, idx, fn _ -> set_path(nil, rest, value) end)
  end

  defp set_path(_data, [key | _rest], _value) when is_list(key) do
    # Array key in path (e.g. setpath([[1]]; 1)) — invalid path element
    throw({:eval_error, "Cannot update field at array index of array"})
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
    if Map.has_key?(data, key) do
      Map.update!(data, key, &delete_path(&1, rest))
    else
      data
    end
  end

  defp delete_path(data, [idx | rest]) when is_list(data) and is_integer(idx) do
    resolved = if idx < 0, do: length(data) + idx, else: idx

    if resolved >= 0 and resolved < length(data) do
      List.update_at(data, resolved, &delete_path(&1, rest))
    else
      data
    end
  end

  defp delete_path(data, _), do: data

  # Delete multiple paths from data simultaneously.
  # Groups deletions by their first path element and resolves all indices/slices
  # against the original data before removing anything, to avoid index shifting.
  defp del_paths(data, paths) do
    # Handle identity path (del(.)) — returns nil
    if Enum.member?(paths, []) do
      nil
    else
      do_del_paths(data, paths)
    end
  end

  defp do_del_paths(data, paths) when is_list(data) do
    len = length(data)

    # Collect all indices to remove at this level, and nested deletions
    {indices_to_remove, nested_deletions} =
      Enum.reduce(paths, {MapSet.new(), %{}}, fn path, {idx_set, nested} ->
        case path do
          [{:slice_del, s, e}] ->
            start_idx = resolve_slice_start(s, len)
            end_idx = resolve_slice_end(e, len)
            start_idx = clamp_index(start_idx, 0, len)
            end_idx = clamp_index(end_idx, 0, len)

            new_indices =
              if start_idx < end_idx, do: Enum.to_list(start_idx..(end_idx - 1)), else: []

            {Enum.reduce(new_indices, idx_set, &MapSet.put(&2, &1)), nested}

          [idx] when is_integer(idx) ->
            resolved = if idx < 0, do: len + idx, else: idx
            {MapSet.put(idx_set, resolved), nested}

          [idx | rest] when is_integer(idx) ->
            resolved = if idx < 0, do: len + idx, else: idx
            existing = Map.get(nested, resolved, [])
            {idx_set, Map.put(nested, resolved, [rest | existing])}

          _ ->
            {idx_set, nested}
        end
      end)

    # First apply nested deletions (these modify elements in-place, don't remove them)
    data =
      Enum.reduce(nested_deletions, data, fn {idx, sub_paths}, acc ->
        if idx >= 0 and idx < length(acc) do
          List.update_at(acc, idx, fn elem -> do_del_paths(elem, sub_paths) end)
        else
          acc
        end
      end)

    # Then remove indices (filter by original index, since nested ops don't change length)
    data
    |> Enum.with_index()
    |> Enum.reject(fn {_val, i} -> MapSet.member?(indices_to_remove, i) end)
    |> Enum.map(fn {val, _i} -> val end)
  end

  defp do_del_paths(data, paths) when is_map(data) do
    # Collect keys to delete at this level, and nested deletions
    {keys_to_remove, nested_deletions} =
      Enum.reduce(paths, {MapSet.new(), %{}}, fn path, {key_set, nested} ->
        case path do
          [key] when is_binary(key) ->
            {MapSet.put(key_set, key), nested}

          [key | rest] when is_binary(key) ->
            existing = Map.get(nested, key, [])
            {key_set, Map.put(nested, key, [rest | existing])}

          _ ->
            {key_set, nested}
        end
      end)

    # Apply nested deletions first
    data =
      Enum.reduce(nested_deletions, data, fn {key, sub_paths}, acc ->
        if Map.has_key?(acc, key) do
          Map.update!(acc, key, fn val -> do_del_paths(val, sub_paths) end)
        else
          acc
        end
      end)

    # Remove top-level keys
    Map.drop(data, MapSet.to_list(keys_to_remove))
  end

  defp do_del_paths(data, _paths), do: data

  defp resolve_slice_start(nil, _len), do: 0
  defp resolve_slice_start(n, len) when is_number(n) and n < 0, do: max(0, len + trunc(n))
  defp resolve_slice_start(n, _len) when is_number(n), do: trunc(n)

  defp resolve_slice_end(nil, len), do: len
  defp resolve_slice_end(n, len) when is_number(n) and n < 0, do: max(0, len + trunc(n))
  defp resolve_slice_end(n, _len) when is_number(n), do: trunc(n)

  defp clamp_index(n, lo, hi), do: max(lo, min(n, hi))

  # Get paths that an expression refers to
  # Validate that an expression is a valid path expression.
  # Non-path expressions (map, sort, etc.) should throw "Invalid path expression with result ..."
  defp valid_path_expr?(:identity), do: true
  defp valid_path_expr?(:iterate), do: true
  defp valid_path_expr?(:empty), do: true
  defp valid_path_expr?(:recurse), do: true
  defp valid_path_expr?({:recursive_descent}), do: true
  defp valid_path_expr?({:field, _}), do: true
  defp valid_path_expr?({:index, _}), do: true
  defp valid_path_expr?({:multi_index, _}), do: true
  defp valid_path_expr?({:optional, inner}), do: valid_path_expr?(inner)
  defp valid_path_expr?({:as, _, _, body}), do: valid_path_expr?(body)

  defp valid_path_expr?({:pipe, left, right}),
    do: valid_path_expr?(left) and valid_path_expr?(right)

  defp valid_path_expr?({:comma, exprs}), do: Enum.all?(exprs, &valid_path_expr?/1)
  defp valid_path_expr?({:postfix_index, base, _}), do: valid_path_expr?(base)
  defp valid_path_expr?({:postfix_multi_index, base, _}), do: valid_path_expr?(base)
  defp valid_path_expr?({:postfix_slice_expr, base, _, _}), do: valid_path_expr?(base)
  defp valid_path_expr?({:slice, _, _}), do: true
  defp valid_path_expr?({:slice_expr, _, _}), do: true
  defp valid_path_expr?({:func, :select, _}), do: true
  defp valid_path_expr?({:func, :first, []}), do: true
  defp valid_path_expr?({:func, :last, []}), do: true
  defp valid_path_expr?({:func, :path, _}), do: true
  defp valid_path_expr?({:func, :recurse, _}), do: true
  defp valid_path_expr?({:func, :getpath, _}), do: true
  defp valid_path_expr?({:func, :type, []}), do: true
  defp valid_path_expr?({:func, :has, _}), do: true
  defp valid_path_expr?({:boolean, _, _, _}), do: true
  defp valid_path_expr?({:comparison, _, _, _}), do: true
  defp valid_path_expr?({:literal, _}), do: true
  defp valid_path_expr?(_), do: false

  defp prepare_func_opts(func_def, args, opts, data, eval) do
    %{params: params, closure_funcs: closure_funcs} = func_def
    current_funcs = Map.get(opts, :user_funcs, %{})
    merged_funcs = Map.merge(closure_funcs, current_funcs)
    func_opts = Map.put(opts, :user_funcs, merged_funcs)

    bind_func_params(params, args, func_opts, opts, data, eval)
  end

  defp bind_func_params(params, args, func_opts, opts, data, eval) do
    Enum.zip(params, args)
    |> Enum.reduce(func_opts, fn {param, arg}, acc_opts ->
      case param do
        {:filter_param, pname} ->
          uf = Map.get(acc_opts, :user_funcs, %{})
          fd = %{params: [], body: arg, closure_funcs: Map.get(opts, :user_funcs, %{})}
          Map.put(acc_opts, :user_funcs, Map.put(uf, {pname, 0}, fd))

        {:value_param, pname} ->
          val = eval.eval(arg, data, opts)
          bindings = Map.get(acc_opts, :bindings, %{})
          Map.put(acc_opts, :bindings, Map.put(bindings, pname, val))
      end
    end)
  end

  defp get_expr_paths_strict(expr, data, opts, eval) do
    get_expr_paths(expr, data, opts, eval, :strict)
  end

  defp get_expr_paths(expr, data, opts, eval) do
    get_expr_paths(expr, data, opts, eval, :lenient)
  end

  # credo:disable-for-lines:300 Credo.Check.Refactor.CyclomaticComplexity
  # credo:disable-for-lines:300 Credo.Check.Refactor.Nesting
  defp get_expr_paths(expr, data, opts, eval, strictness) do
    case expr do
      {:field, name} ->
        [[name]]

      {:index, n} ->
        [[n]]

      {:pipe, left, right} ->
        if strictness == :strict and not valid_path_expr?(left) do
          # Left side is not a valid path expression. Evaluate it to get the result,
          # then report an appropriate error based on what the right side tries to do.
          left_result = eval.eval(left, data, opts)

          left_list =
            case left_result do
              {:multi, items} -> items
              :empty -> []
              item -> [item]
            end

          left_json = Enum.map_join(left_list, ",", fn v -> Jason.encode!(sanitize_nan(v)) end)

          case right do
            {:index, n} ->
              throw(
                {:eval_error,
                 "Invalid path expression near attempt to access element #{n} of #{left_json}"}
              )

            {:field, name} ->
              throw(
                {:eval_error,
                 "Invalid path expression near attempt to access element #{Jason.encode!(name)} of #{left_json}"}
              )

            :iterate ->
              throw(
                {:eval_error,
                 "Invalid path expression near attempt to iterate through #{left_json}"}
              )

            _ ->
              throw({:eval_error, "Invalid path expression with result #{left_json}"})
          end
        else
          left_paths = get_expr_paths(left, data, opts, eval, strictness)

          Enum.flat_map(left_paths, fn lp ->
            left_val = get_path(data, lp)
            right_paths = get_expr_paths(right, left_val, opts, eval, strictness)
            Enum.map(right_paths, fn rp -> lp ++ rp end)
          end)
        end

      :iterate ->
        cond do
          is_map(data) -> Enum.map(Enum.sort(Map.keys(data)), &[&1])
          is_list(data) -> Enum.map(0..(length(data) - 1), &[&1])
          true -> []
        end

      {:recursive_descent} ->
        get_all_paths(data, [])

      {:as, _bind_expr, _pattern, body} ->
        # For path purposes, `as` binding doesn't change the data path.
        # The path is determined by the body expression.
        get_expr_paths(body, data, opts, eval, strictness)

      {:comma, exprs} ->
        Enum.flat_map(exprs, fn e -> get_expr_paths(e, data, opts, eval, strictness) end)

      {:multi_index, idx_expr} ->
        indices = eval.eval_to_list(idx_expr, data, opts)
        indices = Enum.reject(indices, &(&1 == :empty))
        Enum.map(indices, fn idx -> [idx] end)

      {:postfix_multi_index, base_expr, idx_expr} ->
        base_paths = get_expr_paths(base_expr, data, opts, eval, strictness)

        Enum.flat_map(base_paths, fn bp ->
          indices = eval.eval_to_list(idx_expr, data, opts)
          indices = Enum.reject(indices, &(&1 == :empty))

          Enum.map(indices, fn idx ->
            bp ++ [idx]
          end)
        end)

      {:postfix_index, base_expr, idx_expr} ->
        base_paths = get_expr_paths(base_expr, data, opts, eval, strictness)

        case eval.eval(idx_expr, data, opts) do
          {:multi, keys} ->
            Enum.flat_map(base_paths, fn bp ->
              Enum.map(keys, fn key -> bp ++ [key] end)
            end)

          :empty ->
            []

          key ->
            Enum.map(base_paths, fn bp ->
              bp ++ [key]
            end)
        end

      {:optional, inner} ->
        try do
          get_expr_paths(inner, data, opts, eval, strictness)
        catch
          {:eval_error, _} -> []
        end

      :identity ->
        [[]]

      :empty ->
        []

      {:slice, s, e} ->
        [[{:slice_del, s, e}]]

      {:slice_expr, start_expr, end_expr} ->
        start_val = eval.eval(start_expr, data, opts)
        end_val = eval.eval(end_expr, data, opts)
        s = if is_number(start_val), do: trunc(start_val), else: nil
        e = if is_number(end_val), do: trunc(end_val), else: nil
        [[{:slice_del, s, e}]]

      {:postfix_slice_expr, base_expr, start_expr, end_expr} ->
        base_paths = get_expr_paths(base_expr, data, opts, eval, strictness)

        Enum.map(base_paths, fn bp ->
          base_val = get_path(data, bp)
          start_val = eval.eval(start_expr, base_val, opts)
          end_val = eval.eval(end_expr, base_val, opts)
          s = if is_number(start_val), do: trunc(start_val), else: nil
          e = if is_number(end_val), do: trunc(end_val), else: nil
          bp ++ [{:slice_del, s, e}]
        end)

      # select filters paths — only include paths where the condition is truthy
      {:func, :select, [cond_expr]} ->
        case eval.eval(cond_expr, data, opts) do
          val when val in [false, nil] -> []
          :empty -> []
          _ -> [[]]
        end

      # first is equivalent to .[0] for path purposes
      {:func, :first, []} ->
        [[0]]

      # last is equivalent to .[-1] for path purposes
      {:func, :last, []} ->
        [[-1]]

      # User-defined function call — resolve and compute paths through the body
      {:func, name, args} when is_atom(name) ->
        user_funcs = Map.get(opts, :user_funcs, %{})
        arity = length(args)

        case Map.get(user_funcs, {Atom.to_string(name), arity}) do
          nil ->
            # Not a user-defined function — it's a built-in we don't handle as a path
            if strictness == :strict do
              result = eval.eval(expr, data, opts)

              result_list =
                case result do
                  {:multi, items} -> items
                  :empty -> []
                  item -> [item]
                end

              result_json =
                Enum.map_join(result_list, ",", fn v -> Jason.encode!(sanitize_nan(v)) end)

              throw({:eval_error, "Invalid path expression with result #{result_json}"})
            else
              [[]]
            end

          func_def ->
            func_opts = prepare_func_opts(func_def, args, opts, data, eval)
            get_expr_paths(func_def.body, data, func_opts, eval, strictness)
        end

      {:func, name, args} when is_binary(name) ->
        user_funcs = Map.get(opts, :user_funcs, %{})
        arity = length(args)

        case Map.get(user_funcs, {name, arity}) do
          nil ->
            if strictness == :strict do
              result = eval.eval(expr, data, opts)

              result_list =
                case result do
                  {:multi, items} -> items
                  :empty -> []
                  item -> [item]
                end

              result_json =
                Enum.map_join(result_list, ",", fn v -> Jason.encode!(sanitize_nan(v)) end)

              throw({:eval_error, "Invalid path expression with result #{result_json}"})
            else
              [[]]
            end

          func_def ->
            func_opts = prepare_func_opts(func_def, args, opts, data, eval)
            get_expr_paths(func_def.body, data, func_opts, eval, strictness)
        end

      {:def, name, params, body, after_def} ->
        # Register the function definition and compute paths through the after_def body
        user_funcs = Map.get(opts, :user_funcs, %{})
        arity = length(params)
        key = {name, arity}
        func_def = %{params: params, body: body, closure_funcs: user_funcs}
        new_funcs = Map.put(user_funcs, key, func_def)
        new_opts = Map.put(opts, :user_funcs, new_funcs)
        func_def_with_self = %{func_def | closure_funcs: new_funcs}
        new_funcs2 = Map.put(new_funcs, key, func_def_with_self)
        new_opts2 = Map.put(new_opts, :user_funcs, new_funcs2)
        get_expr_paths(after_def, data, new_opts2, eval, strictness)

      _ ->
        if strictness == :strict do
          # Not a valid path expression; evaluate and report result
          result = eval.eval(expr, data, opts)

          result_list =
            case result do
              {:multi, items} -> items
              :empty -> []
              item -> [item]
            end

          result_json =
            Enum.map_join(result_list, ",", fn v -> Jason.encode!(sanitize_nan(v)) end)

          throw({:eval_error, "Invalid path expression with result #{result_json}"})
        else
          [[]]
        end
    end
  end

  # Find all (overlapping) occurrences of pattern in string, returning codepoint offsets
  defp find_string_indices(string, pattern, _offset, _acc) do
    pat_cps = String.codepoints(pattern)
    pat_len = length(pat_cps)
    str_cps = String.codepoints(string)
    do_find_string_indices(str_cps, pat_cps, pat_len, 0, [])
  end

  defp do_find_string_indices([], _pat_cps, _pat_len, _offset, acc) do
    Enum.reverse(acc)
  end

  defp do_find_string_indices(str_cps, pat_cps, pat_len, offset, acc) do
    if length(str_cps) < pat_len do
      Enum.reverse(acc)
    else
      window = Enum.take(str_cps, pat_len)

      if window == pat_cps do
        # Match found at codepoint offset
        do_find_string_indices(tl(str_cps), pat_cps, pat_len, offset + 1, [offset | acc])
      else
        do_find_string_indices(tl(str_cps), pat_cps, pat_len, offset + 1, acc)
      end
    end
  end

  defp find_subarray_indices([], _sub, _offset, acc) do
    Enum.reverse(acc)
  end

  defp find_subarray_indices(data, sub, _offset, acc) when length(data) < length(sub) do
    Enum.reverse(acc)
  end

  defp find_subarray_indices(data, sub, offset, acc) do
    if Enum.take(data, length(sub)) == sub do
      find_subarray_indices(tl(data), sub, offset + 1, [offset | acc])
    else
      find_subarray_indices(tl(data), sub, offset + 1, acc)
    end
  end

  defp parse_datetime_string(str, _fmt) do
    # Try ISO 8601 format first
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        # Try more formats
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} ->
            case DateTime.from_naive(ndt, "Etc/UTC") do
              {:ok, dt} -> {:ok, dt}
              _ -> :error
            end

          _ ->
            :error
        end
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

  @max_iter 100_000

  defp do_until(data, cond_expr, update_expr, opts, eval, depth) do
    if depth > @max_iter, do: throw({:eval_error, "until: exceeded maximum iterations"})

    if truthy?(eval.eval(cond_expr, data, opts)) do
      data
    else
      new_data = eval.eval(update_expr, data, opts)
      do_until(new_data, cond_expr, update_expr, opts, eval, depth + 1)
    end
  end

  defp do_while(data, cond_expr, update_expr, opts, eval, acc) do
    if length(acc) > @max_iter, do: throw({:eval_error, "while: exceeded maximum iterations"})

    if truthy?(eval.eval(cond_expr, data, opts)) do
      new_data = eval.eval(update_expr, data, opts)
      do_while(new_data, cond_expr, update_expr, opts, eval, [data | acc])
    else
      {:multi, Enum.reverse(acc)}
    end
  end

  defp do_repeat(_data, _expr, _opts, _eval, acc, depth) when depth > @max_iter do
    {:multi, Enum.reverse(acc)}
  end

  defp do_repeat(data, expr, opts, eval, acc, depth) do
    result = eval.eval(expr, data, opts)

    case result do
      :empty -> {:multi, Enum.reverse(acc)}
      {:multi, items} -> {:multi, Enum.reverse(acc) ++ items}
      val -> do_repeat(val, expr, opts, eval, [data | acc], depth + 1)
    end
  end

  @max_recurse_depth 512

  defp do_recurse(data, expr, opts, eval, _acc), do: do_recurse(data, expr, opts, eval, [], 0)

  defp do_recurse(_data, _expr, _opts, _eval, _acc, depth) when depth > @max_recurse_depth do
    []
  end

  defp do_recurse(data, expr, opts, eval, _acc, depth) do
    results = eval.eval_to_list(expr, data, opts)
    results = Enum.reject(results, &(&1 == :empty))

    case results do
      [] ->
        [data]

      _ ->
        nested = Enum.flat_map(results, &do_recurse(&1, expr, opts, eval, [], depth + 1))
        [data | nested]
    end
  end

  defp do_walk(data, expr, opts, eval) when is_map(data) do
    walked_pairs =
      Enum.flat_map(data, fn {k, v} ->
        case do_walk(v, expr, opts, eval) do
          :empty -> []
          walked_v -> [{k, walked_v}]
        end
      end)

    transformed = Map.new(walked_pairs)
    eval.eval(expr, transformed, opts)
  end

  defp do_walk(data, expr, opts, eval) when is_list(data) do
    transformed =
      Enum.flat_map(data, fn item ->
        case do_walk(item, expr, opts, eval) do
          :empty -> []
          walked -> [walked]
        end
      end)

    eval.eval(expr, transformed, opts)
  end

  defp do_walk(data, expr, opts, eval) do
    eval.eval(expr, data, opts)
  end

  defp generate_range(current, to, step, acc) when step > 0 and current >= to do
    Enum.reverse(acc)
  end

  defp generate_range(current, to, step, acc) when step < 0 and current <= to do
    Enum.reverse(acc)
  end

  defp generate_range(current, to, step, acc) do
    generate_range(current + step, to, step, [current | acc])
  end

  defp do_bsearch(_data, _x, lo, hi) when lo > hi, do: -1 - lo

  defp do_bsearch(data, x, lo, hi) do
    mid = div(lo + hi, 2)
    val = elem(data, mid)

    cond do
      val == x -> mid
      jq_less_or_equal?(val, x) and val != x -> do_bsearch(data, x, mid + 1, hi)
      true -> do_bsearch(data, x, lo, mid - 1)
    end
  end

  defp number_to_jq_string(n) when is_integer(n), do: Integer.to_string(n)

  defp number_to_jq_string(n) when is_float(n) do
    if n == trunc(n) and abs(n) < 1.0e18,
      do: Integer.to_string(trunc(n)),
      else: Float.to_string(n)
  end

  # Normalize JSON exponents: insert '+' after 'e' when exponent is positive
  # e.g. "1.7976931348623157e308" -> "1.7976931348623157e+308"
  defp normalize_json_exponents(json) do
    Regex.replace(~r/e(\d)/, json, "e+\\1")
  end

  # Encode JSON with a depth limit. When depth exceeds the limit,
  # nested structures are replaced with "<skipped: too deep>".
  defp encode_json_with_depth_limit(data, max_depth) do
    IO.iodata_to_binary(do_encode_depth(data, 0, max_depth))
  end

  defp do_encode_depth(data, depth, max_depth) when is_list(data) do
    if depth >= max_depth do
      ["\"<skipped: too deep>\""]
    else
      inner =
        data
        |> Enum.map(fn item -> do_encode_depth(item, depth + 1, max_depth) end)
        |> Enum.intersperse(",")

      ["[", inner, "]"]
    end
  end

  defp do_encode_depth(data, depth, max_depth) when is_map(data) do
    if depth >= max_depth do
      ["\"<skipped: too deep>\""]
    else
      inner =
        data
        |> Enum.sort_by(fn {k, _v} -> k end)
        |> Enum.map(fn {k, v} ->
          [Jason.encode!(k), ":", do_encode_depth(v, depth + 1, max_depth)]
        end)
        |> Enum.intersperse(",")

      ["{", inner, "}"]
    end
  end

  defp do_encode_depth(data, _depth, _max_depth) do
    Jason.encode!(data)
  end

  # Check if a JSON string exceeds a given nesting depth.
  # Scans the string counting `[` and `{` as depth increments, `]` and `}` as decrements.
  # Skips characters inside strings.
  defp json_exceeds_depth?(str, max_depth) do
    json_depth_scan(str, 0, max_depth, false)
  end

  defp json_depth_scan(<<>>, _depth, _max, _in_string), do: false

  defp json_depth_scan(<<?\\, _, rest::binary>>, depth, max, true) do
    json_depth_scan(rest, depth, max, true)
  end

  defp json_depth_scan(<<?", rest::binary>>, depth, max, in_string) do
    json_depth_scan(rest, depth, max, not in_string)
  end

  defp json_depth_scan(<<c, rest::binary>>, depth, max, false) when c in [?[, ?{] do
    new_depth = depth + 1
    if new_depth > max, do: true, else: json_depth_scan(rest, new_depth, max, false)
  end

  defp json_depth_scan(<<c, rest::binary>>, depth, max, false) when c in [?], ?}] do
    json_depth_scan(rest, depth - 1, max, false)
  end

  defp json_depth_scan(<<_, rest::binary>>, depth, max, in_string) do
    json_depth_scan(rest, depth, max, in_string)
  end

  # Generate a detailed JSON parse error message matching jq's format
  defp json_parse_error_message(input) do
    case find_json_error(input, 1, 1) do
      {:error, msg} -> "#{msg} (while parsing '#{input}')"
      nil -> "Invalid JSON (while parsing '#{input}')"
    end
  end

  defp find_json_error(<<>>, _line, _col), do: nil

  defp find_json_error(<<?\n, rest::binary>>, line, _col) do
    find_json_error(rest, line + 1, 1)
  end

  defp find_json_error(<<c, rest::binary>>, line, col) when c in [?\s, ?\t, ?\r] do
    find_json_error(rest, line, col + 1)
  end

  defp find_json_error(<<?{, rest::binary>>, line, col) do
    find_json_error_after_open(rest, line, col + 1, ?})
  end

  defp find_json_error(<<?[, rest::binary>>, line, col) do
    find_json_error_after_open(rest, line, col + 1, ?])
  end

  defp find_json_error(<<?", rest::binary>>, line, col) do
    scan_json_string(rest, line, col + 1)
  end

  # Single quote — invalid string delimiter
  # jq reports the column AFTER the single-quoted string
  defp find_json_error(<<?', rest::binary>>, line, col) do
    # Scan past the single-quoted string to find end position
    end_col = scan_single_quoted(rest, col + 1)
    {:error, "Invalid string literal; expected \", but got ' at line #{line}, column #{end_col}"}
  end

  defp find_json_error(<<c, _rest::binary>>, _line, _col) when c in [?t, ?f, ?n] do
    # true, false, null — skip for now, assume valid
    nil
  end

  defp find_json_error(<<c, _rest::binary>>, _line, _col) when c in ?0..?9 or c == ?- do
    nil
  end

  defp find_json_error(<<c, _rest::binary>>, line, col) do
    {:error, "Unexpected character '#{<<c>>}' at line #{line}, column #{col}"}
  end

  defp find_json_error_after_open(<<>>, _line, _col, _close), do: nil

  defp find_json_error_after_open(<<?\n, rest::binary>>, line, _col, close) do
    find_json_error_after_open(rest, line + 1, 1, close)
  end

  defp find_json_error_after_open(<<c, rest::binary>>, line, col, close)
       when c in [?\s, ?\t, ?\r] do
    find_json_error_after_open(rest, line, col + 1, close)
  end

  defp find_json_error_after_open(input, line, col, _close) do
    find_json_error(input, line, col)
  end

  # Scan past a single-quoted string, returning the column after the closing quote
  defp scan_single_quoted(<<>>, col), do: col
  defp scan_single_quoted(<<?', rest::binary>>, col), do: col + 1 + count_trailing_spaces(rest)
  defp scan_single_quoted(<<_, rest::binary>>, col), do: scan_single_quoted(rest, col + 1)

  defp count_trailing_spaces(<<?\s, rest::binary>>), do: 1 + count_trailing_spaces(rest)
  defp count_trailing_spaces(_), do: 0

  defp scan_json_string(<<>>, _line, _col), do: nil

  defp scan_json_string(<<?\\, _, rest::binary>>, line, col) do
    scan_json_string(rest, line, col + 2)
  end

  defp scan_json_string(<<?", rest::binary>>, line, col) do
    # End of string — continue scanning
    find_json_error(rest, line, col + 1)
  end

  defp scan_json_string(<<_, rest::binary>>, line, col) do
    scan_json_string(rest, line, col + 1)
  end

  # Convert :nan atoms to nil for JSON encoding compatibility
  defp sanitize_nan(:nan), do: nil
  defp sanitize_nan(list) when is_list(list), do: Enum.map(list, &sanitize_nan/1)

  defp sanitize_nan(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, sanitize_nan(v)} end)
  end

  defp sanitize_nan(other), do: other

  defp builtins_list do
    [
      "abs/0",
      "add/0",
      "all/0",
      "all/1",
      "all/2",
      "any/0",
      "any/1",
      "any/2",
      "arrays/0",
      "ascii/0",
      "ascii_downcase/0",
      "ascii_upcase/0",
      "booleans/0",
      "bsearch/1",
      "builtins/0",
      "capture/1",
      "ceil/0",
      "contains/1",
      "debug/0",
      "debug/1",
      "del/1",
      "delpaths/1",
      "empty/0",
      "endswith/1",
      "env/0",
      "error/0",
      "error/1",
      "exp/0",
      "exp10/0",
      "exp2/0",
      "explode/0",
      "exponent/0",
      "fabs/0",
      "first/0",
      "first/1",
      "flatten/0",
      "flatten/1",
      "floor/0",
      "from_entries/0",
      "fromjson/0",
      "getpath/1",
      "group_by/1",
      "gsub/2",
      "gsub/3",
      "has/1",
      "implode/0",
      "in/1",
      "index/1",
      "indices/1",
      "infinite/0",
      "input/0",
      "inputs/0",
      "inside/1",
      "isempty/1",
      "isfinite/0",
      "isinfinite/0",
      "isnan/0",
      "isnormal/0",
      "iterables/0",
      "join/1",
      "keys/0",
      "keys_unsorted/0",
      "last/0",
      "last/1",
      "leaf_paths/0",
      "length/0",
      "limit/2",
      "log/0",
      "log10/0",
      "log2/0",
      "ltrimstr/1",
      "map/1",
      "map_values/1",
      "match/1",
      "max/0",
      "max_by/1",
      "min/0",
      "min_by/1",
      "mktime/0",
      "modulemeta/0",
      "nan/0",
      "not/0",
      "now/0",
      "nth/1",
      "nth/2",
      "nulls/0",
      "numbers/0",
      "objects/0",
      "path/1",
      "paths/0",
      "paths/1",
      "pick/1",
      "pow/2",
      "range/1",
      "range/2",
      "range/3",
      "recurse/0",
      "recurse/1",
      "repeat/1",
      "reverse/0",
      "rindex/1",
      "round/0",
      "rtrimstr/1",
      "scalars/0",
      "scan/1",
      "select/1",
      "setpath/2",
      "sin/0",
      "cos/0",
      "tan/0",
      "asin/0",
      "acos/0",
      "atan/0",
      "atan2/2",
      "significand/0",
      "skip/2",
      "sort/0",
      "sort_by/1",
      "split/1",
      "split/2",
      "splits/1",
      "splits/2",
      "sqrt/0",
      "startswith/1",
      "strftime/1",
      "strings/0",
      "sub/2",
      "test/1",
      "test/2",
      "to_entries/0",
      "todate/0",
      "tojson/0",
      "tonumber/0",
      "tostring/0",
      "transpose/0",
      "trim/0",
      "ltrim/0",
      "rtrim/0",
      "type/0",
      "unique/0",
      "unique_by/1",
      "until/2",
      "utf8bytelength/0",
      "values/0",
      "walk/1",
      "while/2",
      "with_entries/1",
      "IN/1",
      "IN/2",
      "INDEX/2",
      "JOIN/2",
      "fromdate/0",
      "todate/0",
      "strptime/1",
      "gmtime/0",
      "strflocaltime/1",
      "dateadd/2",
      "datesub/2",
      "have_decnum/0",
      "toboolean/0"
    ]
  end
end
