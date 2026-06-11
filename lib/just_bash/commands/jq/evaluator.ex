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
  alias JustBash.Fs

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
    {:eval_error, msg} ->
      {:error, msg}

    {:eval_error_value, val} ->
      {:error, inspect(val)}

    {:break, name, _} ->
      {:error, "$*label-#{name} is not defined"}

    {:break, name} ->
      {:error, "$*label-#{name} is not defined"}

    {:error_with_results, {:eval_error, msg}, partial_results} ->
      if partial_results == [] do
        {:error, msg}
      else
        # Return partial results — the error is swallowed since we already
        # have output (matching jq's streaming behavior)
        {:ok, partial_results}
      end
  end

  # Public interface for submodules to call back
  @doc false
  def eval(ast, data, opts), do: do_eval(ast, data, opts)

  @doc false
  def eval_to_list(expr, data, opts) do
    case do_eval(expr, data, opts) do
      {:multi, items} -> items
      :empty -> []
      item -> [item]
    end
  end

  @doc false
  def get_module_meta(module_name, opts) when is_binary(module_name) do
    file_path = resolve_module_path(module_name, opts, %{}, :jq)

    case read_virtual_file(opts, file_path) do
      {:ok, content} ->
        module_dir = Path.dirname(file_path)
        module_opts = Map.put(opts, :current_module_dir, module_dir)
        {funcs, module_meta} = parse_module_file(content, module_name, module_opts, %{})

        # Build defs list: ["name/arity", ...]
        defs =
          funcs
          |> Enum.map(fn {{name, arity}, _} -> "#{name}/#{arity}" end)
          |> Enum.sort()

        # Extract deps from module_meta
        deps = Map.get(module_meta, :_deps, [])

        # Build result: module metadata + defs + deps
        result =
          module_meta
          |> Map.delete(:_deps)
          |> Map.put("defs", defs)
          |> Map.put("deps", deps)

        result

      {:error, _} ->
        throw({:eval_error, "module not found: #{module_name}"})
    end
  end

  @doc """
  Evaluate a generator expression, collecting results one-by-one.
  Stops after `n` results are collected (or collects all if n == :all).
  Errors after enough results are collected are suppressed.
  Returns {:ok, results} if enough results were collected,
  or {:error, reason, partial_results} if an error occurred before collecting n results.
  """
  def eval_generator_take(expr, data, opts, n \\ :all) do
    # For comma expressions, evaluate each branch individually
    case expr do
      {:comma, exprs} ->
        take_from_branches(exprs, data, opts, n, [])

      _ ->
        try do
          results = eval_to_list(expr, data, opts)
          results = Enum.reject(results, &(&1 == :empty))

          if n == :all do
            {:ok, results}
          else
            {:ok, Enum.take(results, n)}
          end
        catch
          {:eval_error, reason} -> {:error, reason, []}
          {:eval_error_value, _} = err -> throw(err)
          {:break, _} = brk -> throw(brk)
        end
    end
  end

  defp take_from_branches([], _data, _opts, _n, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp take_from_branches(_exprs, _data, _opts, n, acc)
       when is_integer(n) and length(acc) >= n do
    {:ok, Enum.reverse(acc) |> Enum.take(n)}
  end

  defp take_from_branches([expr | rest], data, opts, n, acc) do
    # credo:disable-for-next-line Credo.Check.Readability.PreferImplicitTry
    try do
      results = eval_to_list(expr, data, opts)
      results = Enum.reject(results, &(&1 == :empty))
      new_acc = Enum.reverse(results) ++ acc

      if is_integer(n) and length(new_acc) >= n do
        {:ok, Enum.reverse(new_acc) |> Enum.take(n)}
      else
        take_from_branches(rest, data, opts, n, new_acc)
      end
    catch
      {:eval_error, reason} ->
        {:error, reason, Enum.reverse(acc)}

      {:eval_error_value, _} = err ->
        throw(err)

      {:break, _} = brk ->
        throw(brk)
    end
  end

  # Result wrapping
  defp wrap_results({:multi, list}) when is_list(list), do: list
  defp wrap_results(other), do: [other]

  # Module directives - import/include/module
  defp do_eval({:module_directives, directives, body}, data, opts) do
    opts = process_module_directives(directives, opts)
    do_eval(body, data, opts)
  end

  # Namespace function access: foo::bar
  defp do_eval({:ns_func, ns, func_name, args}, data, opts) do
    namespaces = Map.get(opts, :namespaces, %{})

    case Map.get(namespaces, ns) do
      nil ->
        throw({:eval_error, "#{ns}/0 is not defined"})

      ns_funcs ->
        func_name_str = if is_atom(func_name), do: Atom.to_string(func_name), else: func_name
        key = {func_name_str, length(args)}

        case Map.get(ns_funcs, key) do
          nil ->
            throw({:eval_error, "#{ns}::#{func_name}/#{length(args)} is not defined"})

          func_def ->
            eval_user_func(func_def, args, data, opts)
        end
    end
  end

  # Namespace data access: $d::name
  defp do_eval({:ns_data, var_name, field_name}, _data, opts) do
    bindings = Map.get(opts, :bindings, %{})

    case Map.get(bindings, var_name) do
      nil ->
        throw({:eval_error, "variable $#{var_name} not defined"})

      data_val ->
        # Access the field from the data binding
        # In jq, $d::d accesses the imported data under the namespace
        namespaces = Map.get(opts, :data_namespaces, %{})

        case Map.get(namespaces, var_name) do
          nil ->
            # Direct variable access
            if is_map(data_val), do: Map.get(data_val, field_name), else: nil

          ns_data ->
            Map.get(ns_data, field_name)
        end
    end
  end

  # Core evaluation - primitives
  defp do_eval(:identity, data, _opts), do: data
  defp do_eval(:empty, _data, _opts), do: :empty
  defp do_eval({:literal, value}, _data, _opts), do: value

  defp do_eval({:var, "__loc__"}, _data, _opts) do
    %{"file" => "<top-level>", "line" => 1}
  end

  defp do_eval({:var, name}, _data, opts) do
    bindings = Map.get(opts, :bindings, %{})

    case Map.fetch(bindings, name) do
      {:ok, val} -> val
      :error -> throw({:eval_error, "variable $#{name} not defined"})
    end
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

  defp do_eval({:field, name}, data, _opts) do
    throw({:eval_error, "Cannot index #{type_name_for_error(data)} with string \"#{name}\""})
  end

  defp do_eval({:index, n}, data, _opts) when is_list(data) and is_integer(n) do
    if n < 0 do
      len = length(data)
      idx = len + n
      if idx >= 0, do: Enum.at(data, idx), else: nil
    else
      Enum.at(data, n)
    end
  end

  defp do_eval({:index, n}, data, _opts) when is_list(data) and is_float(n) do
    # Float index — jq truncates to integer (floor) for array access
    idx = floor(n) |> trunc()
    if idx < 0, do: Enum.at(data, length(data) + idx), else: Enum.at(data, idx)
  end

  defp do_eval({:index, _n}, nil, _opts), do: nil

  defp do_eval({:index, n}, data, _opts) when is_binary(data) and is_integer(n) do
    # String indexing
    len = String.length(data)
    idx = if n < 0, do: len + n, else: n
    if idx >= 0 and idx < len, do: String.at(data, idx), else: nil
  end

  defp do_eval({:index, n}, data, _opts) when is_binary(data) and is_float(n) do
    throw({:eval_error, "Cannot index string with number"})
  end

  defp do_eval({:index, n}, data, _opts) when is_number(n) do
    throw({:eval_error, "Cannot index #{type_name_for_error(data)} with number"})
  end

  defp do_eval({:index, n}, _data, _opts) do
    throw({:eval_error, "Cannot index with #{inspect(n)}"})
  end

  # Multi-index: .[1,2,3] — returns multiple values
  defp do_eval({:multi_index, expr}, data, opts) do
    indices = eval_to_list(expr, data, opts)

    results =
      Enum.map(indices, fn idx ->
        cond do
          is_integer(idx) and is_list(data) -> do_eval({:index, idx}, data, opts)
          is_float(idx) and is_list(data) -> do_eval({:index, idx}, data, opts)
          is_binary(idx) and is_map(data) -> Map.get(data, idx)
          true -> nil
        end
      end)

    {:multi, results}
  end

  # Dynamic index: .[expr] where expr is computed at runtime
  defp do_eval({:dynamic_index, expr}, data, opts) do
    key = do_eval(expr, data, opts)
    apply_dynamic_key(key, data)
  end

  # Postfix dynamic index: base[expr] where expr is evaluated against original input
  defp do_eval({:postfix_index, base_expr, idx_expr}, data, opts) do
    base = do_eval(base_expr, data, opts)
    key = do_eval(idx_expr, data, opts)
    apply_dynamic_key(key, base)
  end

  # Postfix multi-index: base[a,b,c] where index exprs are evaluated against original input
  defp do_eval({:postfix_multi_index, base_expr, idx_expr}, data, opts) do
    base = do_eval(base_expr, data, opts)
    do_eval({:multi_index, idx_expr}, base, opts)
  end

  # Postfix slice with expressions: base[start:end] where exprs are evaluated against original input
  defp do_eval({:postfix_slice_expr, base_expr, start_expr, end_expr}, data, opts) do
    base = do_eval(base_expr, data, opts)
    start_val = do_eval(start_expr, data, opts)
    end_val = do_eval(end_expr, data, opts)
    start_n = to_slice_start(start_val)
    end_n = to_slice_end(end_val)
    do_eval({:slice, start_n, end_n}, base, opts)
  end

  defp do_eval({:slice, start_idx, end_idx}, data, _opts) when is_list(data) do
    len = length(data)
    # jq uses floor() for start, ceil() for end with floats
    start_idx = jq_slice_start(start_idx)
    end_idx = jq_slice_end(end_idx)
    start_idx = normalize_slice_index(start_idx, len, 0)
    end_idx = normalize_slice_index(end_idx, len, len)
    start_idx = clamp(start_idx, 0, len)
    end_idx = clamp(end_idx, 0, len)

    if start_idx >= end_idx do
      []
    else
      Enum.slice(data, start_idx..(end_idx - 1)//1)
    end
  end

  defp do_eval({:slice, start_idx, end_idx}, data, _opts) when is_binary(data) do
    len = String.length(data)
    start_idx = jq_slice_start(start_idx)
    end_idx = jq_slice_end(end_idx)
    start_idx = normalize_slice_index(start_idx, len, 0)
    end_idx = normalize_slice_index(end_idx, len, len)
    start_idx = clamp(start_idx, 0, len)
    end_idx = clamp(end_idx, 0, len)

    if start_idx >= end_idx do
      ""
    else
      String.slice(data, start_idx..(end_idx - 1)//1)
    end
  end

  defp do_eval({:slice, _start, _end}, nil, _opts), do: nil

  defp do_eval({:slice, _start, _end}, data, _opts) do
    throw({:eval_error, "Cannot slice #{type_name_for_error(data)}"})
  end

  # Slice with expression endpoints
  defp do_eval({:slice_expr, start_expr, end_expr}, data, opts) do
    start_val = do_eval(start_expr, data, opts)
    end_val = do_eval(end_expr, data, opts)
    # Convert to numeric slice: jq uses floor() for start, ceil() for end
    start_n = to_slice_start(start_val)
    end_n = to_slice_end(end_val)
    do_eval({:slice, start_n, end_n}, data, opts)
  end

  # Iteration
  defp do_eval(:iterate, data, _opts) when is_list(data), do: {:multi, data}
  defp do_eval(:iterate, data, _opts) when is_map(data), do: {:multi, Map.values(data)}
  defp do_eval(:iterate, nil, _opts), do: {:multi, []}

  defp do_eval(:iterate, data, _opts) do
    desc = value_desc_for_error(data)
    throw({:eval_error, "Cannot iterate over #{desc}"})
  end

  defp do_eval({:optional, expr}, data, opts) do
    eval_optional(expr, data, opts)
  end

  # Pipe and comma
  defp do_eval({:pipe, left, right}, data, opts) do
    left_result = do_eval(left, data, opts)
    eval_pipe_right(left_result, right, opts)
  end

  defp do_eval({:comma, exprs}, data, opts) do
    results = eval_comma_parts(exprs, data, opts, [])
    {:multi, results}
  end

  # Array and object construction
  defp do_eval({:array, [expr]}, data, opts) do
    result = do_eval(expr, data, opts)
    array_from_result(result)
  end

  defp do_eval({:array, []}, _data, _opts), do: []

  defp do_eval({:object, pairs}, data, opts) do
    eval_object_pairs(pairs, data, opts, %{})
  end

  # Comparison and boolean operators — handle multi-value results
  defp do_eval({:comparison, op, left, right}, data, opts) do
    left_val = do_eval(left, data, opts)
    right_val = do_eval(right, data, opts)

    case {left_val, right_val} do
      {{:multi, l_items}, {:multi, r_items}} ->
        results =
          Enum.flat_map(r_items, fn rv ->
            Enum.map(l_items, fn lv -> compare(op, lv, rv) end)
          end)

        {:multi, results}

      {{:multi, l_items}, _} ->
        results = Enum.map(l_items, fn lv -> compare(op, lv, right_val) end)
        {:multi, results}

      {_, {:multi, r_items}} ->
        results = Enum.map(r_items, fn rv -> compare(op, left_val, rv) end)
        {:multi, results}

      _ ->
        compare(op, left_val, right_val)
    end
  end

  defp do_eval({:boolean, :and, left, right}, data, opts) do
    left_val = do_eval(left, data, opts)

    if truthy?(left_val) do
      right_val = do_eval(right, data, opts)
      truthy?(right_val)
    else
      false
    end
  end

  defp do_eval({:boolean, :or, left, right}, data, opts) do
    left_val = do_eval(left, data, opts)

    if truthy?(left_val) do
      true
    else
      right_val = do_eval(right, data, opts)
      truthy?(right_val)
    end
  end

  defp do_eval({:alternative, left, right}, data, opts) do
    eval_alternative(left, right, data, opts)
  end

  defp do_eval({:not, expr}, data, opts) do
    val = do_eval(expr, data, opts)
    not truthy?(val)
  end

  # Update assignment operators: +=, -=, *=, /=, //=, %=, |=
  defp do_eval({:update_assign, op, path_expr, value_expr}, data, opts) do
    validate_assignment_path(path_expr, data, opts)
    eval_update_assign(op, path_expr, value_expr, data, opts)
  end

  # Plain assignment: .foo = expr
  defp do_eval({:assign, path_expr, value_expr}, data, opts) do
    validate_assignment_path(path_expr, data, opts)

    results = eval_to_list(value_expr, data, opts)

    case results do
      [] ->
        :empty

      _ ->
        {:multi,
         Enum.map(results, fn val ->
           set_at_path(path_expr, val, data, opts)
         end)}
    end
  end

  # Control flow
  defp do_eval({:if, cond_expr, then_expr, else_expr}, data, opts) do
    cond_results = eval_to_list(cond_expr, data, opts)

    results =
      Enum.flat_map(cond_results, fn cond_val ->
        branch = if truthy?(cond_val), do: then_expr, else: else_expr

        case do_eval(branch, data, opts) do
          {:multi, items} -> items
          :empty -> []
          item -> [item]
        end
      end)

    case results do
      [] -> :empty
      [single] -> single
      multi -> {:multi, multi}
    end
  end

  defp do_eval({:try, expr, catch_expr}, data, opts) do
    eval_try(expr, catch_expr, data, opts)
  end

  # Legacy form without catch
  defp do_eval({:try, expr}, data, opts) do
    eval_try(expr, nil, data, opts)
  end

  # Try-alternative: expr ?// alt
  defp do_eval({:try_alt, expr, alt}, data, opts) do
    result = do_eval(expr, data, opts)

    case result do
      :empty -> do_eval(alt, data, opts)
      _ -> result
    end
  catch
    {:eval_error, _} -> do_eval(alt, data, opts)
  end

  # `as` binding: EXPR as PATTERN | BODY
  defp do_eval({:as, expr, pattern, body}, data, opts) do
    values = eval_to_list(expr, data, opts)

    results =
      Enum.flat_map(values, fn val ->
        case bind_pattern(pattern, val, opts) do
          {:ok, new_opts} ->
            case do_eval(body, data, new_opts) do
              {:multi, items} -> items
              :empty -> []
              item -> [item]
            end

          :error ->
            # Pattern didn't match — skip (for try_alt_patterns, handled below)
            []
        end
      end)

    case results do
      [] -> :empty
      [single] -> single
      multi -> {:multi, multi}
    end
  end

  # def: function definition
  defp do_eval({:def, name, params, body, after_def}, data, opts) do
    # Store the function definition in opts
    user_funcs = Map.get(opts, :user_funcs, %{})
    arity = length(params)
    key = {name, arity}
    # Capture closure over current user_funcs (lexical scope at definition time)
    # Store self_key so eval_user_func can re-add self for recursion
    func_def = %{params: params, body: body, closure_funcs: user_funcs, self_key: key}
    new_funcs = Map.put(user_funcs, key, func_def)
    new_opts = Map.put(opts, :user_funcs, new_funcs)
    do_eval(after_def, data, new_opts)
  end

  # label/break
  defp do_eval({:label, name, body}, data, opts) do
    do_eval(body, data, opts)
  catch
    {:break, ^name} ->
      :empty

    {:break_with_results, ^name, partial_results} ->
      # Break thrown mid-stream during pipe evaluation.
      # Return the results collected before the break.
      case partial_results do
        [] -> :empty
        [single] -> single
        multi -> {:multi, multi}
      end
  end

  defp do_eval({:break, name}, _data, _opts) do
    throw({:break, name})
  end

  # Reduce with pattern
  defp do_eval({:reduce, expr, pattern, init, update}, data, opts) do
    items = eval_to_list(expr, data, opts)
    init_val = do_eval(init, data, opts)

    Enum.reduce(items, init_val, fn item, acc ->
      case bind_pattern(pattern, item, opts) do
        {:ok, new_opts} ->
          case do_eval(update, acc, new_opts) do
            {:multi, [single]} -> single
            {:multi, [last | _]} -> last
            other -> other
          end

        :error ->
          acc
      end
    end)
  end

  # Foreach with pattern
  defp do_eval({:foreach, expr, pattern, init, update, extract}, data, opts) do
    items = eval_to_list(expr, data, opts)
    init_vals = eval_to_list(init, data, opts)

    results =
      Enum.flat_map(init_vals, fn init_val ->
        r = do_foreach(items, pattern, init_val, update, extract, opts, [])
        Enum.reject(r, &(&1 == :empty))
      end)

    {:multi, results}
  end

  defp do_eval({:recursive_descent}, data, _opts), do: {:multi, recursive_descent(data)}

  # Arithmetic operators — handle multi-value results from subexpressions
  defp do_eval({:arith, op, left, right}, data, opts) do
    eval_arith(op, left, right, data, opts)
  end

  # Function calls - delegate to Functions module
  # In jq, function arguments that produce multiple values cause the function
  # to be called for each combination (cartesian product).
  defp do_eval({:func, name, args}, data, opts) do
    # Check user-defined functions first
    user_funcs = Map.get(opts, :user_funcs, %{})
    arity = length(args)
    name_str = if is_atom(name), do: Atom.to_string(name), else: name
    key = {name_str, arity}

    case Map.fetch(user_funcs, key) do
      {:ok, func_def} ->
        eval_user_func(func_def, args, data, opts)

      :error ->
        # Some functions handle multi-value args internally (like IN, any, all)
        # and should not have their args expanded via cartesian product
        if has_multi_value_args?(args) and not multi_value_exempt?(name, length(args)) do
          eval_func_multi_args(name, args, data, opts)
        else
          Functions.eval_func(name, args, data, opts, __MODULE__)
        end
    end
  end

  # Format strings - delegate to Format module
  defp do_eval({:format, format_type}, data, _opts) do
    Format.format(format_type, data)
  end

  # Format with string interpolation: @html "string"
  # In jq, @format "string" applies the format only to the interpolated parts,
  # not the literal string parts.
  defp do_eval({:format_str, format_type, {:string_interp, parts}}, data, opts) do
    Enum.map_join(parts, fn
      {:str, s} ->
        s

      {:interp, expr} ->
        val = do_eval(expr, data, opts)
        Format.format(format_type, Format.stringify(val))
    end)
  end

  defp do_eval({:format_str, format_type, str_ast}, data, opts) do
    str = do_eval(str_ast, data, opts)
    Format.format(format_type, str)
  end

  # Catch-all for unsupported expressions
  defp do_eval(other, _data, _opts) do
    throw({:eval_error, "unsupported expression: #{inspect(other)}"})
  end

  defp apply_dynamic_key(key, data) do
    cond do
      key == :nan ->
        nil

      is_integer(key) and is_list(data) ->
        do_eval({:index, key}, data, %{})

      is_float(key) and is_list(data) ->
        do_eval({:index, key}, data, %{})

      is_binary(key) and is_map(data) ->
        Map.get(data, key)

      is_nil(key) ->
        nil

      is_list(data) and data == [] ->
        nil

      is_map(data) ->
        nil

      is_binary(key) ->
        throw(
          {:eval_error, "Cannot index #{type_name_for_error(data)} with string #{inspect(key)}"}
        )

      is_number(key) ->
        throw({:eval_error, "Cannot index #{type_name_for_error(data)} with number"})

      true ->
        throw(
          {:eval_error,
           "Cannot index #{type_name_for_error(data)} with #{type_name_for_error(key)}"}
        )
    end
  end

  # foreach helper that catches breaks and preserves partial results
  defp do_foreach([], _pattern, _acc, _update, _extract, _opts, results) do
    Enum.reverse(results)
  end

  defp do_foreach([item | rest], pattern, acc, update, extract, opts, results) do
    case bind_pattern(pattern, item, opts) do
      {:ok, new_opts} ->
        # Only wrap the update and extract in try/catch, NOT the recursive call.
        # If break happens during update/extract, we include results so far.
        # If break propagates from recursion, it already has all results.
        {new_acc, extracted} =
          try do
            na = do_eval(update, acc, new_opts)
            ex = do_eval(extract, na, new_opts)
            {na, ex}
          catch
            {:break, label} ->
              throw({:break_with_results, label, Enum.reverse(results)})
          end

        do_foreach(rest, pattern, new_acc, update, extract, opts, [extracted | results])

      :error ->
        do_foreach(rest, pattern, acc, update, extract, opts, results)
    end
  end

  # Pattern binding for `as` expressions
  defp bind_pattern({:pat_var, name}, value, opts) do
    bindings = Map.get(opts, :bindings, %{})
    {:ok, Map.put(opts, :bindings, Map.put(bindings, name, value))}
  end

  defp bind_pattern({:pat_array, _patterns}, value, _opts) when not is_list(value) do
    # Try to match — if value isn't a list, it's a mismatch
    # For try_alt_patterns, return :error
    :error
  end

  defp bind_pattern({:pat_array, patterns}, value, opts) when is_list(value) do
    bind_array_patterns(patterns, value, 0, opts)
  end

  defp bind_pattern({:pat_object, key_patterns}, value, opts) do
    # Validate computed key types before checking if value is a map
    # jq rejects non-string keys like (true), (0) even if the value isn't an object
    Enum.each(key_patterns, fn
      {:expr_key, key_expr, _pat} ->
        key = do_eval(key_expr, value, opts)

        unless is_binary(key) do
          throw({:eval_error, "Cannot use #{jq_value_desc(key)} as object key"})
        end

      _ ->
        :ok
    end)

    if is_map(value) do
      bind_object_patterns(key_patterns, value, opts)
    else
      :error
    end
  end

  defp bind_pattern({:try_alt_patterns, patterns}, value, opts) do
    # Collect all variable names from all patterns and pre-initialize to nil.
    # This ensures that variables from non-matching patterns are available as null.
    all_vars = Enum.flat_map(patterns, &collect_pattern_vars/1) |> Enum.uniq()
    bindings = Map.get(opts, :bindings, %{})
    pre_bound = Enum.reduce(all_vars, bindings, fn v, b -> Map.put(b, v, nil) end)
    opts_with_defaults = Map.put(opts, :bindings, pre_bound)

    Enum.reduce_while(patterns, :error, fn pat, _acc ->
      case bind_pattern(pat, value, opts_with_defaults) do
        {:ok, new_opts} -> {:halt, {:ok, new_opts}}
        :error -> {:cont, :error}
      end
    end)
  end

  defp bind_array_patterns([], _value, _idx, opts), do: {:ok, opts}

  defp bind_array_patterns([pat | rest], value, idx, opts) do
    elem = Enum.at(value, idx)

    case bind_pattern(pat, elem, opts) do
      {:ok, new_opts} -> bind_array_patterns(rest, value, idx + 1, new_opts)
      :error -> :error
    end
  end

  defp bind_object_patterns([], _value, opts), do: {:ok, opts}

  defp bind_object_patterns([{key, pat} | rest], value, opts) when is_binary(key) do
    val = Map.get(value, key)

    case bind_pattern(pat, val, opts) do
      {:ok, new_opts} -> bind_object_patterns(rest, value, new_opts)
      :error -> :error
    end
  end

  defp bind_object_patterns([{:var_key, var_name, pat} | rest], value, opts) do
    # {$b: pattern} — use var_name as the key string, bind $var_name to the value,
    # and also destructure the value into the sub-pattern
    key = var_name
    val = Map.get(value, key)
    # First bind $var_name to val
    bindings = Map.get(opts, :bindings, %{})
    opts = Map.put(opts, :bindings, Map.put(bindings, var_name, val))

    case bind_pattern(pat, val, opts) do
      {:ok, new_opts} -> bind_object_patterns(rest, value, new_opts)
      :error -> :error
    end
  end

  defp bind_object_patterns([{:expr_key, key_expr, pat} | rest], value, opts) do
    key = do_eval(key_expr, value, opts)

    unless is_binary(key) do
      throw({:eval_error, "Cannot use #{jq_value_desc(key)} as object key"})
    end

    val = Map.get(value, key)

    case bind_pattern(pat, val, opts) do
      {:ok, new_opts} -> bind_object_patterns(rest, value, new_opts)
      :error -> :error
    end
  end

  # Collect all variable names referenced in a pattern (for pre-initializing to nil)
  defp collect_pattern_vars({:pat_var, name}), do: [name]

  defp collect_pattern_vars({:pat_array, patterns}) do
    Enum.flat_map(patterns, &collect_pattern_vars/1)
  end

  defp collect_pattern_vars({:pat_object, key_patterns}) do
    Enum.flat_map(key_patterns, fn
      {_key, pat} -> collect_pattern_vars(pat)
      {:var_key, var_name, pat} -> [var_name | collect_pattern_vars(pat)]
      {:expr_key, _expr, pat} -> collect_pattern_vars(pat)
    end)
  end

  defp collect_pattern_vars({:try_alt_patterns, patterns}) do
    Enum.flat_map(patterns, &collect_pattern_vars/1)
  end

  defp collect_pattern_vars(_), do: []

  @max_call_depth 256

  # Check if any function argument is a comma expression (produces multiple values)
  defp has_multi_value_args?(args) do
    Enum.any?(args, fn
      {:comma, _} -> true
      _ -> false
    end)
  end

  # Some functions handle multi-value args internally and should NOT have
  # their args expanded via cartesian product
  defp multi_value_exempt?(:IN, 1), do: true
  defp multi_value_exempt?(:IN, 2), do: true
  defp multi_value_exempt?(:any, 2), do: true
  defp multi_value_exempt?(:all, 2), do: true
  defp multi_value_exempt?(:isempty, 1), do: true
  defp multi_value_exempt?(:first, 1), do: true
  defp multi_value_exempt?(:last, 1), do: true
  defp multi_value_exempt?(:limit, 2), do: true
  defp multi_value_exempt?(:nth, 2), do: true
  defp multi_value_exempt?(:until, 2), do: true
  defp multi_value_exempt?(:while, 2), do: true
  defp multi_value_exempt?(:repeat, 1), do: true
  defp multi_value_exempt?(:recurse, 1), do: true
  defp multi_value_exempt?(:reduce, _), do: true
  defp multi_value_exempt?(:foreach, _), do: true
  defp multi_value_exempt?(:del, 1), do: true
  defp multi_value_exempt?(:add, 1), do: true
  defp multi_value_exempt?(:map, 1), do: true
  defp multi_value_exempt?(:map_values, 1), do: true
  defp multi_value_exempt?(:select, 1), do: true
  defp multi_value_exempt?(:path, 1), do: true
  defp multi_value_exempt?(:paths, 1), do: true
  defp multi_value_exempt?(:env, _), do: true
  defp multi_value_exempt?(:sort_by, 1), do: true
  defp multi_value_exempt?(:unique_by, 1), do: true
  defp multi_value_exempt?(:group_by, 1), do: true
  defp multi_value_exempt?(:min_by, 1), do: true
  defp multi_value_exempt?(:max_by, 1), do: true
  defp multi_value_exempt?(_, _), do: false

  # Evaluate a function call where some arguments produce multiple values.
  # Expands comma args into their individual values, then calls the function
  # for each combination (cartesian product).
  defp eval_func_multi_args(name, args, data, opts) do
    # For each arg, get the list of values it produces
    arg_value_lists =
      Enum.map(args, fn arg ->
        case arg do
          {:comma, _} ->
            # Multi-value arg — evaluate to get all values, wrap each as a literal
            values = eval_to_list(arg, data, opts)
            Enum.map(values, fn v -> {:literal, v} end)

          _ ->
            [arg]
        end
      end)

    # Compute cartesian product of all arg lists
    combos = cartesian_product(arg_value_lists)

    # Call the function for each combination
    results =
      Enum.flat_map(combos, fn arg_combo ->
        case Functions.eval_func(name, arg_combo, data, opts, __MODULE__) do
          {:multi, items} -> items
          :empty -> []
          item -> [item]
        end
      end)

    case results do
      [] -> :empty
      [single] -> single
      multi -> {:multi, multi}
    end
  end

  defp cartesian_product([]), do: [[]]

  defp cartesian_product([head | tail]) do
    tail_combos = cartesian_product(tail)

    Enum.flat_map(head, fn item ->
      Enum.map(tail_combos, fn combo -> [item | combo] end)
    end)
  end

  # User-defined function evaluation
  defp eval_user_func(func_def, args, data, opts) do
    depth = Map.get(opts, :call_depth, 0)
    if depth > @max_call_depth, do: throw({:eval_error, "stack overflow"})
    opts = Map.put(opts, :call_depth, depth + 1)

    %{params: params, body: body, closure_funcs: closure_funcs} = func_def

    # Use closure's function definitions (lexical scoping)
    # The function body sees ONLY the functions that existed when it was defined,
    # plus itself (for recursion)
    func_env = closure_funcs

    func_env =
      case Map.get(func_def, :self_key) do
        nil -> func_env
        self_key -> Map.put(func_env, self_key, func_def)
      end

    func_opts = Map.put(opts, :user_funcs, func_env)

    # Restore closure bindings if this is a filter param thunk
    func_opts =
      case Map.get(func_def, :closure_bindings) do
        nil -> func_opts
        closure_bindings -> Map.put(func_opts, :bindings, closure_bindings)
      end

    # Restore closure namespaces for module functions
    func_opts =
      case Map.get(func_def, :closure_namespaces) do
        nil -> func_opts
        ns when map_size(ns) > 0 -> Map.put(func_opts, :namespaces, ns)
        _ -> func_opts
      end

    func_opts =
      case Map.get(func_def, :closure_data_namespaces) do
        nil -> func_opts
        ns when map_size(ns) > 0 -> Map.put(func_opts, :data_namespaces, ns)
        _ -> func_opts
      end

    # Bind parameters — filter params capture the caller's scope for evaluation
    caller_opts = opts

    # Separate filter params and value params
    param_args = Enum.zip(params, args)

    {filter_params, value_params} =
      Enum.split_with(param_args, fn {param, _arg} ->
        match?({:filter_param, _}, param)
      end)

    # Bind filter params to thunks in function scope
    func_opts =
      Enum.reduce(filter_params, func_opts, fn {{:filter_param, name}, arg}, acc_opts ->
        user_funcs = Map.get(acc_opts, :user_funcs, %{})

        thunk_def = %{
          params: [],
          body: arg,
          closure_funcs: Map.get(caller_opts, :user_funcs, %{}),
          closure_bindings: Map.get(caller_opts, :bindings, %{})
        }

        new_funcs = Map.put(user_funcs, {name, 0}, thunk_def)
        Map.put(acc_opts, :user_funcs, new_funcs)
      end)

    # Value params: expand multi-values via iteration (like `as` bindings)
    # y($a;$b) called with (x;y) is equivalent to x as $a | y as $b | body
    eval_value_params(value_params, body, data, func_opts, caller_opts)
  end

  # No more value params to bind — evaluate the body
  defp eval_value_params([], body, data, func_opts, _caller_opts) do
    do_eval(body, data, func_opts)
  end

  # Bind value params one at a time, expanding multi-values
  defp eval_value_params([{{:value_param, name}, arg} | rest], body, data, func_opts, caller_opts) do
    val = do_eval(arg, data, caller_opts)

    case val do
      {:multi, items} ->
        results =
          Enum.flat_map(items, fn item ->
            bindings = Map.get(func_opts, :bindings, %{})
            opts_with_binding = Map.put(func_opts, :bindings, Map.put(bindings, name, item))
            result = eval_value_params(rest, body, data, opts_with_binding, caller_opts)

            case result do
              {:multi, sub_items} -> sub_items
              :empty -> []
              single -> [single]
            end
          end)

        case results do
          [] -> :empty
          [single] -> single
          multi -> {:multi, multi}
        end

      :empty ->
        :empty

      single ->
        bindings = Map.get(func_opts, :bindings, %{})
        opts_with_binding = Map.put(func_opts, :bindings, Map.put(bindings, name, single))
        eval_value_params(rest, body, data, opts_with_binding, caller_opts)
    end
  end

  # Pipe helper - handles multi-value results
  defp eval_pipe_right({:multi, results}, right, opts) do
    filtered_results = Enum.reject(results, &(&1 == :empty))

    multi_results = eval_pipe_multi(filtered_results, right, opts, [])
    {:multi, multi_results}
  end

  defp eval_pipe_right(:empty, _right, _opts), do: :empty

  defp eval_pipe_right(left_result, right, opts) do
    do_eval(right, left_result, opts)
  end

  # Evaluate comma parts collecting results, catching breaks to preserve partial results
  defp eval_comma_parts([], _data, _opts, acc), do: acc |> Enum.reverse() |> Enum.concat()

  defp eval_comma_parts([expr | rest], data, opts, acc) do
    new_results =
      try do
        case do_eval(expr, data, opts) do
          {:multi, inner} -> inner
          :empty -> []
          other -> [other]
        end
      catch
        {:break, label} ->
          throw({:break_with_results, label, acc |> Enum.reverse() |> Enum.concat()})

        {:break_with_results, label, inner_results} ->
          our_results = acc |> Enum.reverse() |> Enum.concat()
          throw({:break_with_results, label, our_results ++ inner_results})
      end

    eval_comma_parts(rest, data, opts, [new_results | acc])
  end

  # Evaluate right side of pipe for each item, collecting results.
  # If a break is thrown, we re-throw with partial results attached.
  defp eval_pipe_multi([], _right, _opts, acc), do: acc |> Enum.reverse() |> Enum.concat()

  defp eval_pipe_multi([item | rest], right, opts, acc) do
    new_results =
      try do
        case do_eval(right, item, opts) do
          {:multi, inner} -> inner
          :empty -> []
          other -> [other]
        end
      catch
        {:break, label} ->
          # Re-throw the break but include partial results collected so far
          throw({:break_with_results, label, acc |> Enum.reverse() |> Enum.concat()})

        {:break_with_results, label, inner_results} ->
          # A nested pipe already collected some results before the break.
          # Combine our collected results with the inner results.
          our_results = acc |> Enum.reverse() |> Enum.concat()
          throw({:break_with_results, label, our_results ++ inner_results})

        {:eval_error, _} = err ->
          # Error in one value of the generator. Preserve partial results
          # collected so far and re-throw with them.
          our_results = acc |> Enum.reverse() |> Enum.concat()
          throw({:error_with_results, err, our_results})

        {:error_with_results, err, inner_results} ->
          our_results = acc |> Enum.reverse() |> Enum.concat()
          throw({:error_with_results, err, our_results ++ inner_results})
      end

    eval_pipe_multi(rest, right, opts, [new_results | acc])
  end

  # Array construction helper
  defp array_from_result({:multi, items}), do: Enum.reject(items, &(&1 == :empty))
  defp array_from_result(:empty), do: []
  defp array_from_result(other), do: [other]

  # Object construction with multi-value support
  # acc is a list of partial objects being built
  defp eval_object_pairs([], _data, _opts, acc), do: acc

  # credo:disable-for-lines:50 Credo.Check.Refactor.Nesting
  defp eval_object_pairs([{key_expr, val_expr} | rest], data, opts, acc) do
    keys = eval_to_list(key_expr, data, opts)
    vals = eval_to_list(val_expr, data, opts)

    # Validate all keys are strings — jq rejects non-string object keys
    Enum.each(keys, fn k ->
      unless is_binary(k) do
        throw({:eval_error, "Cannot use #{jq_value_desc(k)} as object key"})
      end
    end)

    # For each combination of key and value, and for each existing partial object,
    # produce a new partial object. This handles multi-value keys/values correctly.
    case {keys, vals} do
      {[k], [v]} ->
        # Common fast path: single key, single value
        new_acc = Map.put(acc, k, v)
        eval_object_pairs(rest, data, opts, new_acc)

      _ ->
        # Multiple keys or values — produce multiple objects via cartesian product
        combos =
          for k <- keys, v <- vals do
            {k, v}
          end

        case combos do
          [{k, v}] ->
            eval_object_pairs(rest, data, opts, Map.put(acc, k, v))

          _ ->
            # Need to produce multiple objects
            combos
            |> Enum.map(fn {k, v} -> Map.put(acc, k, v) end)
            |> Enum.flat_map(fn obj ->
              case eval_object_pairs(rest, data, opts, obj) do
                {:multi, items} -> items
                item -> [item]
              end
            end)
            |> then(fn
              [single] -> single
              multi -> {:multi, multi}
            end)
        end
    end
  end

  # Arithmetic evaluation with multi-value support
  # In jq, if a subexpression in arithmetic produces multiple values,
  # the arithmetic is performed for each combination.

  # Special case: unary negation (0 - expr)
  defp eval_arith(:sub, {:literal, 0}, right, data, opts) do
    r = do_eval(right, data, opts)

    case r do
      {:multi, items} ->
        results = Enum.map(items, &negate_value/1)
        {:multi, results}

      :empty ->
        :empty

      val ->
        negate_value(val)
    end
  end

  defp eval_arith(op, left, right, data, opts) do
    l = do_eval(left, data, opts)
    r = do_eval(right, data, opts)
    apply_arith_multi(op, l, r)
  end

  defp apply_arith_multi(op, {:multi, l_items}, {:multi, r_items}) do
    results =
      Enum.flat_map(r_items, fn rv ->
        Enum.map(l_items, fn lv -> apply_arith_op(op, lv, rv) end)
      end)

    {:multi, results}
  end

  defp apply_arith_multi(op, {:multi, l_items}, r) do
    results = Enum.map(l_items, fn lv -> apply_arith_op(op, lv, r) end)
    {:multi, results}
  end

  defp apply_arith_multi(op, l, {:multi, r_items}) do
    results = Enum.map(r_items, fn rv -> apply_arith_op(op, l, rv) end)
    {:multi, results}
  end

  defp apply_arith_multi(_op, :empty, _), do: :empty
  defp apply_arith_multi(_op, _, :empty), do: :empty

  defp apply_arith_multi(op, l, r), do: apply_arith_op(op, l, r)

  defp apply_arith_op(:add, l, r), do: arith_add(l, r)
  defp apply_arith_op(:sub, l, r), do: arith_sub(l, r)
  defp apply_arith_op(:mul, l, r), do: arith_mul(l, r)
  defp apply_arith_op(:div, l, r), do: arith_div(l, r)
  defp apply_arith_op(:mod, l, r), do: arith_mod(l, r)

  defp negate_value(:nan), do: :nan

  defp negate_value(v) when is_number(v) do
    result = -v
    if is_float(result) and result == trunc(result), do: trunc(result), else: result
  end

  defp negate_value(v) when is_binary(v) do
    throw({:eval_error, "string (#{jq_truncate_string(v)}) cannot be negated"})
  end

  defp negate_value(nil), do: nil

  defp negate_value(v) do
    throw({:eval_error, "#{type_name_for_error(v)} cannot be negated"})
  end

  # Arithmetic helpers — :nan propagation
  defp arith_add(:nan, _), do: :nan
  defp arith_add(_, :nan), do: :nan

  defp arith_add(l, r) when is_number(l) and is_number(r) do
    result = l + r
    if is_float(result) and result == trunc(result), do: trunc(result), else: result
  end

  defp arith_add(l, r) when is_binary(l) and is_binary(r), do: l <> r
  defp arith_add(l, r) when is_list(l) and is_list(r), do: l ++ r
  defp arith_add(l, r) when is_map(l) and is_map(r), do: Map.merge(l, r)
  defp arith_add(nil, r), do: r
  defp arith_add(l, nil), do: l

  defp arith_add(l, r) do
    throw(
      {:eval_error, "#{type_name_for_error(l)} and #{type_name_for_error(r)} cannot be added"}
    )
  end

  defp arith_sub(:nan, _), do: :nan
  defp arith_sub(_, :nan), do: :nan

  defp arith_sub(l, r) when is_number(l) and is_number(r) do
    result = l - r
    if is_float(result) and result == trunc(result), do: trunc(result), else: result
  end

  defp arith_sub(l, r) when is_list(l) and is_list(r) do
    Enum.reject(l, fn x -> Enum.member?(r, x) end)
  end

  defp arith_sub(l, r) do
    throw({:eval_error, "#{jq_value_desc(l)} and #{jq_value_desc(r)} cannot be subtracted"})
  end

  # NaN * string → nil (same as negative number * string)
  defp arith_mul(:nan, s) when is_binary(s), do: nil
  defp arith_mul(s, :nan) when is_binary(s), do: nil
  # NaN * number or number * NaN → :nan
  defp arith_mul(:nan, _), do: :nan
  defp arith_mul(_, :nan), do: :nan

  defp arith_mul(l, r) when is_number(l) and is_number(r) do
    result = l * r
    if is_float(result) and result == trunc(result), do: trunc(result), else: result
  end

  # String * number or number * string repetition
  defp arith_mul(s, n) when is_binary(s) and is_number(n) do
    cond do
      n < 0 ->
        nil

      s == "" ->
        ""

      n == 0 ->
        ""

      true ->
        count = trunc(n)

        if count <= 0 do
          ""
        else
          if count > 100_000, do: throw({:eval_error, "Repeat string result too long"})
          String.duplicate(s, count)
        end
    end
  end

  defp arith_mul(n, s) when is_number(n) and is_binary(s) do
    arith_mul(s, n)
  end

  # nil * anything → nil (jq: null * x = null for strings, used for nan behavior)
  defp arith_mul(nil, _), do: nil
  defp arith_mul(_, nil), do: nil

  # Object * object merge
  defp arith_mul(l, r) when is_map(l) and is_map(r) do
    Map.merge(l, r, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2), do: arith_mul(v1, v2), else: v2
    end)
  end

  defp arith_mul(_l, _r) do
    throw({:eval_error, "bad argument in arithmetic expression"})
  end

  defp arith_div(l, r) when is_number(l) and is_number(r) do
    if r == 0,
      do:
        throw(
          {:eval_error,
           "number (#{l}) and number (0) cannot be divided because the divisor is zero"}
        )

    result = l / r
    if result == trunc(result), do: trunc(result), else: result
  end

  # String / string split
  defp arith_div(l, r) when is_binary(l) and is_binary(r) do
    String.split(l, r)
  end

  defp arith_div(:nan, _), do: :nan
  defp arith_div(_, :nan), do: :nan

  defp arith_div(nil, _), do: nil
  defp arith_div(_, nil), do: nil

  defp arith_div(_l, _r) do
    throw({:eval_error, "bad argument in arithmetic expression"})
  end

  defp arith_mod(:nan, _), do: :nan
  defp arith_mod(_, :nan), do: :nan

  defp arith_mod(l, r) when is_integer(l) and is_integer(r) do
    if r == 0,
      do:
        throw(
          {:eval_error,
           "number (#{l}) and number (0) cannot be divided (remainder) because the divisor is zero"}
        )

    rem(l, r)
  end

  defp arith_mod(l, r) when is_number(l) and is_number(r) do
    if r == 0,
      do:
        throw(
          {:eval_error,
           "number (#{l}) and number (0) cannot be divided (remainder) because the divisor is zero"}
        )

    # jq uses C's (intmax_t) cast then integer %. For very large floats, the
    # cast overflows to LLONG_MAX/LLONG_MIN on most platforms.
    li = clamp_to_int64(trunc(l))
    ri = clamp_to_int64(trunc(r))

    if ri == 0,
      do:
        throw(
          {:eval_error,
           "number (#{l}) and number (0) cannot be divided (remainder) because the divisor is zero"}
        )

    rem(li, ri)
  end

  defp arith_mod(nil, _), do: nil
  defp arith_mod(_, nil), do: nil

  defp arith_mod(_l, _r) do
    throw({:eval_error, "bad argument in arithmetic expression"})
  end

  # jq-style value description for error messages: type ("truncated_value...")
  defp jq_value_desc(v) when is_binary(v) do
    "string (#{jq_truncate_string(v)})"
  end

  defp jq_value_desc(:nan), do: "number (null)"
  defp jq_value_desc(v) when is_number(v), do: "number (#{v})"
  defp jq_value_desc(nil), do: "null"
  defp jq_value_desc(v) when is_boolean(v), do: "boolean (#{v})"
  defp jq_value_desc(v) when is_list(v), do: "array"
  defp jq_value_desc(v) when is_map(v), do: "object"

  # jq truncates strings in error messages to approximately 10 bytes
  # Format: "first~10bytes..." (no closing quote)
  defp jq_truncate_string(s) when is_binary(s) do
    escaped = String.replace(s, "\"", "\\\"")

    if byte_size(s) > 10 do
      # Truncate at byte level, but ensure valid UTF-8
      truncated = truncate_at_bytes(s, 10)
      truncated_escaped = String.replace(truncated, "\"", "\\\"")
      "\"#{truncated_escaped}..."
    else
      "\"#{escaped}\""
    end
  end

  # Truncate string to approximately max_bytes, keeping valid UTF-8
  defp truncate_at_bytes(s, max_bytes) do
    s
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, bytes} ->
      new_bytes = bytes + byte_size(grapheme)

      if new_bytes > max_bytes do
        {:halt, {acc, bytes}}
      else
        {:cont, {acc <> grapheme, new_bytes}}
      end
    end)
    |> elem(0)
  end

  defp type_name_for_error(:nan), do: "number"
  defp type_name_for_error(nil), do: "null"
  defp type_name_for_error(v) when is_boolean(v), do: "boolean"
  defp type_name_for_error(v) when is_number(v), do: "number"
  defp type_name_for_error(v) when is_binary(v), do: "string"
  defp type_name_for_error(v) when is_list(v), do: "array"
  defp type_name_for_error(v) when is_map(v), do: "object"
  defp type_name_for_error(_), do: "unknown"

  # Value description with type and value, e.g. "number (123)"
  defp value_desc_for_error(:nan), do: "number (null)"
  defp value_desc_for_error(nil), do: "null (null)"
  defp value_desc_for_error(v) when is_boolean(v), do: "boolean (#{v})"
  defp value_desc_for_error(v) when is_number(v), do: "number (#{v})"
  defp value_desc_for_error(v) when is_binary(v), do: "string (#{inspect(v)})"
  defp value_desc_for_error(v) when is_list(v), do: "array (#{Jason.encode!(v)})"
  defp value_desc_for_error(v) when is_map(v), do: "object (#{Jason.encode!(v)})"
  defp value_desc_for_error(v), do: "#{inspect(v)}"

  defp to_num(:nan), do: :nan
  defp to_num(n) when is_number(n), do: n

  defp to_num(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_num(_), do: throw({:eval_error, "bad argument in arithmetic expression"})

  # Comparison helpers - jq comparison semantics
  defp compare(:eq, a, b), do: jq_equal?(a, b)
  defp compare(:neq, a, b), do: not jq_equal?(a, b)

  defp compare(:lt, a, b) do
    case jq_compare(a, b) do
      :lt -> true
      _ -> false
    end
  end

  defp compare(:gt, a, b) do
    case jq_compare(a, b) do
      :gt -> true
      _ -> false
    end
  end

  defp compare(:lte, a, b) do
    case jq_compare(a, b) do
      :gt -> false
      _ -> true
    end
  end

  defp compare(:gte, a, b) do
    case jq_compare(a, b) do
      :lt -> false
      _ -> true
    end
  end

  defp jq_equal?(:nan, _), do: false
  defp jq_equal?(_, :nan), do: false
  defp jq_equal?(a, b) when is_number(a) and is_number(b), do: a == b
  defp jq_equal?(a, b), do: a == b

  # jq comparison: null < false < true < numbers < strings < arrays < objects
  # NaN comparisons: NaN is not ordered, treat as equal for comparison purposes
  defp jq_compare(:nan, :nan), do: :eq
  defp jq_compare(:nan, b) when is_number(b), do: :eq
  defp jq_compare(a, :nan) when is_number(a), do: :eq

  defp jq_compare(a, b) when is_number(a) and is_number(b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  defp jq_compare(a, b) when is_binary(a) and is_binary(b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  defp jq_compare(a, b) do
    ta = type_order(a)
    tb = type_order(b)

    cond do
      ta < tb -> :lt
      ta > tb -> :gt
      # Same type - compare structurally
      true -> structural_compare(a, b)
    end
  end

  defp type_order(:nan), do: 3
  defp type_order(nil), do: 0
  defp type_order(false), do: 1
  defp type_order(true), do: 2
  defp type_order(n) when is_number(n), do: 3
  defp type_order(s) when is_binary(s), do: 4
  defp type_order(l) when is_list(l), do: 5
  defp type_order(m) when is_map(m), do: 6

  defp structural_compare(a, b) when is_list(a) and is_list(b) do
    Enum.zip(a, b)
    |> Enum.reduce_while(:eq, fn {x, y}, _acc ->
      case jq_compare(x, y) do
        :eq -> {:cont, :eq}
        other -> {:halt, other}
      end
    end)
    |> case do
      :eq ->
        cond do
          length(a) < length(b) -> :lt
          length(a) > length(b) -> :gt
          true -> :eq
        end

      other ->
        other
    end
  end

  defp structural_compare(a, b) when is_map(a) and is_map(b) do
    # Compare objects by sorted keys, then values
    keys_a = Map.keys(a) |> Enum.sort()
    keys_b = Map.keys(b) |> Enum.sort()

    case structural_compare(keys_a, keys_b) do
      :eq ->
        vals_a = Enum.map(keys_a, &Map.get(a, &1))
        vals_b = Enum.map(keys_b, &Map.get(b, &1))
        structural_compare(vals_a, vals_b)

      other ->
        other
    end
  end

  defp structural_compare(_, _), do: :eq

  # Boolean helper
  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true

  # Index normalization for slices
  defp normalize_slice_index(nil, _len, default), do: default

  defp normalize_slice_index(n, len, _default) when is_number(n) and n < 0,
    do: max(0, len + trunc(n))

  defp normalize_slice_index(n, _len, _default) when is_number(n), do: trunc(n)

  # jq uses floor() for slice start, ceil() for slice end
  defp to_slice_start(nil), do: nil
  defp to_slice_start(n) when is_integer(n), do: n
  defp to_slice_start(n) when is_float(n), do: floor(n) |> trunc()
  defp to_slice_start(_), do: nil

  defp to_slice_end(nil), do: nil
  defp to_slice_end(n) when is_integer(n), do: n
  defp to_slice_end(n) when is_float(n), do: ceil(n) |> trunc()
  defp to_slice_end(_), do: nil

  # Convert float slice indices: floor for start, ceil for end
  defp jq_slice_start(n) when is_float(n), do: floor(n) |> trunc()
  defp jq_slice_start(n), do: n

  defp jq_slice_end(n) when is_float(n), do: ceil(n) |> trunc()
  defp jq_slice_end(n), do: n

  defp clamp(n, lo, hi), do: max(lo, min(n, hi))

  # Simulate C's (intmax_t) cast for very large integers.
  # On most platforms, overflow clamps to LLONG_MAX/LLONG_MIN.
  @int64_max 9_223_372_036_854_775_807
  @int64_min -9_223_372_036_854_775_808
  defp clamp_to_int64(n) when n > @int64_max, do: @int64_max
  defp clamp_to_int64(n) when n < @int64_min, do: @int64_min
  defp clamp_to_int64(n), do: n

  # Recursive descent helper
  defp recursive_descent(data) when is_map(data) do
    values = Map.values(data)
    [data | Enum.flat_map(values, &recursive_descent/1)]
  end

  defp recursive_descent(data) when is_list(data) do
    [data | Enum.flat_map(data, &recursive_descent/1)]
  end

  defp recursive_descent(data), do: [data]

  # Error-handling helpers with implicit catch
  defp eval_optional(expr, data, opts) do
    result = do_eval(expr, data, opts)

    case result do
      {:multi, items} ->
        filtered = Enum.reject(items, &(&1 == :empty))
        if filtered == [], do: :empty, else: {:multi, filtered}

      other ->
        other
    end
  catch
    {:eval_error, _} -> :empty
    {:error_with_results, _, _} -> :empty
  end

  defp eval_alternative(left, right, data, opts) do
    left_results = eval_to_list(left, data, opts)
    # Filter out null/false values
    non_null = Enum.reject(left_results, fn v -> v == nil or v == false end)

    if non_null != [] do
      case non_null do
        [single] -> single
        multi -> {:multi, multi}
      end
    else
      do_eval(right, data, opts)
    end
  catch
    {:eval_error, _} -> do_eval(right, data, opts)
  end

  defp eval_try(expr, nil, data, opts) do
    result = do_eval(expr, data, opts)

    case result do
      {:multi, items} ->
        # Filter out errors — in try without catch, errors become empty
        {:multi, items}

      other ->
        other
    end
  catch
    {:eval_error, _} ->
      :empty

    {:eval_error_value, _} ->
      :empty

    {:break, _, _} ->
      :empty

    {:error_with_results, _, partial_results} ->
      # Generator produced some results before erroring. Return partial results.
      case partial_results do
        [] -> :empty
        [single] -> single
        multi -> {:multi, multi}
      end
  end

  defp eval_try(expr, catch_expr, data, opts) do
    do_eval(expr, data, opts)
  catch
    {:eval_error, msg} ->
      # Bind the error message and evaluate catch expression
      do_eval(catch_expr, msg, opts)

    {:eval_error_value, val} ->
      # Non-string error value — pass raw value to catch
      do_eval(catch_expr, val, opts)

    {:break, _, _} ->
      do_eval(catch_expr, "break", opts)

    {:error_with_results, {:eval_error, msg}, partial_results} ->
      # Generator produced some results before erroring.
      # Return partial results + the caught error result.
      caught = do_eval(catch_expr, msg, opts)

      caught_list =
        case caught do
          {:multi, items} -> items
          :empty -> []
          item -> [item]
        end

      case partial_results ++ caught_list do
        [] -> :empty
        [single] -> single
        multi -> {:multi, multi}
      end
  end

  # Validate that a path expression used in assignment is valid.
  # Non-path expressions (map, reverse, etc.) should throw an error.
  defp validate_assignment_path(path_expr, data, opts) do
    case find_invalid_path_segment(path_expr) do
      nil ->
        :ok

      {:non_path, invalid_expr, right_access} ->
        # Evaluate the invalid expression to get its result for the error message
        result = do_eval(invalid_expr, data, opts)

        result_list =
          case result do
            {:multi, items} -> items
            :empty -> []
            item -> [item]
          end

        result_json =
          Enum.map_join(result_list, ",", fn v -> Jason.encode!(sanitize_for_json(v)) end)

        case right_access do
          :iterate ->
            throw(
              {:eval_error,
               "Invalid path expression near attempt to iterate through #{result_json}"}
            )

          {:field, name} ->
            throw(
              {:eval_error,
               "Invalid path expression near attempt to access element #{Jason.encode!(name)} of #{result_json}"}
            )

          {:index, n} ->
            throw(
              {:eval_error,
               "Invalid path expression near attempt to access element #{n} of #{result_json}"}
            )

          nil ->
            throw({:eval_error, "Invalid path expression with result #{result_json}"})
        end
    end
  end

  # Find the first non-path segment in a path expression.
  # Returns nil if the expression is a valid path, or {:non_path, invalid_expr, right_access}
  # credo:disable-for-lines:60 Credo.Check.Refactor.CyclomaticComplexity
  defp find_invalid_path_segment(expr) do
    case expr do
      :identity ->
        nil

      :iterate ->
        nil

      :empty ->
        nil

      :recurse ->
        nil

      {:field, _} ->
        nil

      {:index, _} ->
        nil

      {:multi_index, _} ->
        nil

      {:literal, _} ->
        nil

      {:slice, _, _} ->
        nil

      {:slice_expr, _, _} ->
        nil

      {:func, :select, _} ->
        nil

      {:func, :first, []} ->
        nil

      {:func, :last, []} ->
        nil

      {:func, :path, _} ->
        nil

      {:func, :recurse, _} ->
        nil

      {:func, :getpath, _} ->
        nil

      {:func, :type, []} ->
        nil

      {:func, :has, _} ->
        nil

      {:dynamic_index, _} ->
        nil

      {:recursive_descent} ->
        nil

      {:optional, inner} ->
        find_invalid_path_segment(inner)

      {:as, _expr, _pattern, body} ->
        find_invalid_path_segment(body)

      {:boolean, _, _, _} ->
        nil

      {:pipe, left, right} ->
        case find_invalid_path_segment(left) do
          nil ->
            # Left is valid, check right
            find_invalid_path_segment(right)

          {:non_path, invalid_expr, access} when access != nil ->
            # Left already has a specific access context — propagate it
            {:non_path, invalid_expr, access}

          {:non_path, _invalid_expr, nil} ->
            # Left is invalid but doesn't know the access yet.
            # The right side is the "access" being attempted.
            {:non_path, left, first_path_access(right)}
        end

      {:comma, exprs} ->
        Enum.find_value(exprs, &find_invalid_path_segment/1)

      {:postfix_index, base, _} ->
        find_invalid_path_segment(base)

      {:postfix_multi_index, base, _} ->
        find_invalid_path_segment(base)

      {:postfix_slice_expr, base, _, _} ->
        find_invalid_path_segment(base)

      # Function calls — check if it's a known data-transforming built-in
      # These CANNOT be path expressions because they produce new data, not path navigation
      {:func, name, _args} ->
        if non_path_builtin?(name) do
          {:non_path, expr, nil}
        else
          # Could be a user-defined function or a path-compatible builtin
          # (select, first, last, getpath, recurse, path, etc.)
          nil
        end

      {:def, _, _, _body, after_def} ->
        find_invalid_path_segment(after_def)

      _ ->
        {:non_path, expr, nil}
    end
  end

  # Built-in functions that transform data and CANNOT be used as path expressions
  defp non_path_builtin?(name) do
    name in [
      :map,
      :map_values,
      :sort,
      :sort_by,
      :reverse,
      :group_by,
      :unique,
      :unique_by,
      :flatten,
      :min,
      :max,
      :min_by,
      :max_by,
      :add,
      :keys,
      :keys_unsorted,
      :values,
      :to_entries,
      :from_entries,
      :with_entries,
      :tojson,
      :fromjson,
      :tonumber,
      :tostring,
      :ascii_downcase,
      :ascii_upcase,
      :ltrimstr,
      :rtrimstr,
      :implode,
      :explode,
      :join,
      :split,
      :test,
      :match,
      :capture,
      :scan,
      :sub,
      :gsub,
      :splits,
      :contains,
      :inside,
      :length,
      :utf8bytelength,
      :not,
      :range,
      :env,
      :builtins,
      :floor,
      :ceil,
      :round,
      :sqrt,
      :fabs,
      :pow,
      :log,
      :exp,
      :nan,
      :infinite,
      :isinfinite,
      :isnan,
      :isnormal,
      :isfinite,
      :transpose,
      :indices,
      :index,
      :rindex,
      :walk,
      :pick,
      :startswith,
      :endswith,
      :error,
      :debug,
      :stderr,
      :ascii,
      :format,
      :input,
      :inputs,
      :delpaths,
      :leaf_paths,
      :del,
      :setpath,
      :strftime,
      :strflocaltime,
      :mktime,
      :gmtime,
      :now,
      :todate,
      :fromdate,
      :halt,
      :halt_error
    ]
  end

  # Extract the first path access from an expression (for error messages)
  defp first_path_access(:iterate), do: :iterate
  defp first_path_access({:field, _} = f), do: f
  defp first_path_access({:index, _} = i), do: i
  defp first_path_access({:pipe, left, _}), do: first_path_access(left)
  defp first_path_access(_), do: nil

  defp sanitize_for_json(:nan), do: nil
  defp sanitize_for_json(list) when is_list(list), do: Enum.map(list, &sanitize_for_json/1)

  defp sanitize_for_json(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, sanitize_for_json(v)} end)

  defp sanitize_for_json(other), do: other

  # Update assignment helpers
  defp eval_update_assign(op, path_expr, value_expr, data, opts) do
    # Special case: |= empty means DELETE the matched elements
    # Use path-based deletion (like del())
    if op == :pipe and value_expr == :empty do
      eval_update_assign_empty(path_expr, data, opts)
    else
      eval_update_assign_impl(op, path_expr, value_expr, data, opts)
    end
  end

  # Handle |= empty: delete all elements at matched paths
  defp eval_update_assign_empty(path_expr, data, opts) do
    paths = Functions.eval_func(:path, [path_expr], data, opts, __MODULE__)

    path_list =
      case paths do
        {:multi, items} -> items
        :empty -> []
        item -> [item]
      end

    Functions.eval_func(:delpaths, [{:literal, path_list}], data, opts, __MODULE__)
  end

  defp eval_update_assign_impl(op, path_expr, value_expr, data, opts) do
    case path_expr do
      :identity ->
        # . |= expr — update the entire value
        compute_update_value(op, data, value_expr, data, opts)

      :iterate ->
        # .[] |= expr — update all elements
        update_all_elements(op, value_expr, data, opts)

      {:pipe, left, right} ->
        # Check if left might produce multiple values (recursive descent, etc.)
        # In that case, use path-based update
        if needs_path_based_update?(left) do
          eval_path_based_update(op, path_expr, value_expr, data, opts)
        else
          # .foo.bar |= expr — nested path update
          eval_nested_update(op, left, right, value_expr, data, opts)
        end

      {:multi_index, _} ->
        # .[1,2,3] |= expr — multi-index update
        eval_update_assign_multi(op, path_expr, value_expr, data, opts)

      _ ->
        if simple_path_expr?(path_expr) do
          # Simple path that set_at_path knows how to handle directly
          current_val = do_eval(path_expr, data, opts)
          new_val = compute_update_value(op, current_val, value_expr, data, opts)
          set_at_path(path_expr, new_val, data, opts)
        else
          # Complex path (user-defined functions, etc.) — use path-based update
          eval_path_based_update(op, path_expr, value_expr, data, opts)
        end
    end
  end

  defp simple_path_expr?({:field, _}), do: true
  defp simple_path_expr?({:index, _}), do: true
  defp simple_path_expr?({:dynamic_index, _}), do: true
  defp simple_path_expr?({:slice, _, _}), do: true
  defp simple_path_expr?({:slice_expr, _, _}), do: true
  defp simple_path_expr?({:optional, inner}), do: simple_path_expr?(inner)
  defp simple_path_expr?({:func, :getpath, _}), do: true
  defp simple_path_expr?({:as, _, _, body}), do: simple_path_expr?(body)
  defp simple_path_expr?({:comma, _}), do: false
  defp simple_path_expr?({:func, _, _}), do: false
  defp simple_path_expr?({:def, _, _, _}), do: false
  defp simple_path_expr?(_), do: true

  defp needs_path_based_update?({:recursive_descent}), do: true
  defp needs_path_based_update?({:pipe, left, _}), do: needs_path_based_update?(left)
  defp needs_path_based_update?(_), do: false

  # Path-based update: compute all paths, then update each
  defp eval_path_based_update(op, path_expr, value_expr, data, opts) do
    paths = Functions.eval_func(:path, [path_expr], data, opts, __MODULE__)

    path_list =
      case paths do
        {:multi, items} -> items
        :empty -> []
        item -> [item]
      end

    Enum.reduce(path_list, data, fn path, acc ->
      current_val = get_in_path(acc, path)
      new_val = compute_update_value(op, current_val, value_expr, data, opts)
      set_nested_path(acc, path, new_val)
    end)
  end

  defp get_in_path(data, []), do: data

  defp get_in_path(data, [key | rest]) when is_map(data) and is_binary(key) do
    get_in_path(Map.get(data, key), rest)
  end

  defp get_in_path(data, [idx | rest]) when is_list(data) and is_integer(idx) do
    idx = if idx < 0, do: length(data) + idx, else: idx
    get_in_path(Enum.at(data, idx), rest)
  end

  defp get_in_path(_data, _path), do: nil

  defp set_nested_path(_data, [], value), do: value

  defp set_nested_path(data, [key | rest], value) when is_map(data) and is_binary(key) do
    current = Map.get(data, key)
    Map.put(data, key, set_nested_path(current, rest, value))
  end

  defp set_nested_path(data, [idx | rest], value) when is_list(data) and is_integer(idx) do
    idx = if idx < 0, do: length(data) + idx, else: idx
    current = Enum.at(data, idx)
    List.replace_at(data, idx, set_nested_path(current, rest, value))
  end

  defp set_nested_path(data, _path, _value), do: data

  defp eval_nested_update(op, left, right, value_expr, data, opts) do
    intermediate = do_eval(left, data, opts)

    updated_intermediate =
      eval_update_assign(op, right, value_expr, intermediate, opts)

    set_at_path(left, updated_intermediate, data, opts)
  end

  defp update_all_elements(op, value_expr, data, opts) when is_list(data) do
    Enum.map(data, fn item ->
      compute_update_value(op, item, value_expr, data, opts)
    end)
    |> Enum.reject(&(&1 == :empty))
  end

  defp update_all_elements(op, value_expr, data, opts) when is_map(data) do
    Map.new(data, fn {k, v} ->
      new_val = compute_update_value(op, v, value_expr, data, opts)
      {k, new_val}
    end)
  end

  defp eval_update_assign_multi(op, {:multi_index, idx_expr}, value_expr, data, opts)
       when is_list(data) do
    indices =
      eval_to_list(idx_expr, data, opts)
      |> MapSet.new()

    Enum.with_index(data)
    |> Enum.map(fn {item, i} ->
      if MapSet.member?(indices, i) do
        compute_update_value(op, item, value_expr, item, opts)
      else
        item
      end
    end)
    |> Enum.reject(&(&1 == :empty))
  end

  # For |= (pipe), value_expr is evaluated with current_val as input
  defp compute_update_value(:pipe, current_val, value_expr, _original_data, opts) do
    do_eval(value_expr, current_val, opts)
  end

  # For +=, -=, etc., value_expr is evaluated with ORIGINAL data as input
  defp compute_update_value(:add, current_val, value_expr, original_data, opts) do
    update_val = do_eval(value_expr, original_data, opts)
    arith_add(current_val, update_val)
  end

  defp compute_update_value(:sub, current_val, value_expr, original_data, opts) do
    update_val = do_eval(value_expr, original_data, opts)
    arith_sub(to_num(current_val), to_num(update_val))
  end

  defp compute_update_value(:mul, current_val, value_expr, original_data, opts) do
    update_val = do_eval(value_expr, original_data, opts)
    arith_mul(to_num(current_val), to_num(update_val))
  end

  defp compute_update_value(:div, current_val, value_expr, original_data, opts) do
    update_val = do_eval(value_expr, original_data, opts)
    arith_div(to_num(current_val), to_num(update_val))
  end

  defp compute_update_value(:mod, current_val, value_expr, original_data, opts) do
    update_val = do_eval(value_expr, original_data, opts)
    arith_mod(to_num(current_val), to_num(update_val))
  end

  defp compute_update_value(:alt, current_val, value_expr, original_data, opts) do
    if current_val == nil or current_val == false do
      do_eval(value_expr, original_data, opts)
    else
      current_val
    end
  end

  # Set value at a path expression
  defp set_at_path({:field, name}, value, data, _opts) when is_map(data) do
    Map.put(data, name, value)
  end

  defp set_at_path({:field, name}, value, nil, _opts) do
    %{name => value}
  end

  defp set_at_path({:index, idx}, value, data, _opts) when is_list(data) do
    idx = if is_float(idx), do: floor(idx) |> trunc(), else: idx
    idx = if idx < 0, do: length(data) + idx, else: idx

    if idx < 0 do
      throw({:eval_error, "array index out of bounds"})
    end

    if idx > 100_000, do: throw({:eval_error, "Array index too large"})

    # Extend array if needed
    data =
      if idx >= length(data) do
        data ++ List.duplicate(nil, idx + 1 - length(data))
      else
        data
      end

    List.replace_at(data, idx, value)
  end

  defp set_at_path({:index, idx}, value, nil, _opts) do
    idx = if is_float(idx), do: floor(idx) |> trunc(), else: idx
    if idx < 0, do: throw({:eval_error, "Out of bounds negative array index"})
    if idx > 100_000, do: throw({:eval_error, "Array index too large"})
    list = List.duplicate(nil, idx + 1)
    List.replace_at(list, idx, value)
  end

  defp set_at_path({:pipe, left, right}, value, data, opts) do
    intermediate = do_eval(left, data, opts)
    updated_intermediate = set_at_path(right, value, intermediate, opts)
    set_at_path(left, updated_intermediate, data, opts)
  end

  defp set_at_path(:iterate, value, data, _opts) when is_list(data) do
    Enum.map(data, fn _ -> value end)
  end

  defp set_at_path(:iterate, value, data, _opts) when is_map(data) do
    Map.new(data, fn {k, _v} -> {k, value} end)
  end

  defp set_at_path({:slice_expr, start_expr, end_expr}, value, data, opts) do
    start_val = do_eval(start_expr, data, opts)
    end_val = do_eval(end_expr, data, opts)
    start_n = to_slice_start(start_val)
    end_n = to_slice_end(end_val)
    set_at_path({:slice, start_n, end_n}, value, data, opts)
  end

  defp set_at_path({:slice, start_idx, end_idx}, value, data, _opts)
       when is_list(data) and is_list(value) do
    len = length(data)
    s = jq_slice_start(start_idx) |> normalize_slice_index(len, 0) |> clamp(0, len)
    e = jq_slice_end(end_idx) |> normalize_slice_index(len, len) |> clamp(0, len)
    Enum.slice(data, 0, s) ++ value ++ Enum.drop(data, e)
  end

  defp set_at_path({:slice, _, _}, _value, data, _opts) when is_binary(data) do
    throw({:eval_error, "Cannot update string slices"})
  end

  defp set_at_path({:dynamic_index, idx_expr}, value, data, opts) do
    key = do_eval(idx_expr, data, opts)

    if key == :nan do
      throw({:eval_error, "Cannot set array element at NaN index"})
    end

    cond do
      is_integer(key) and is_list(data) ->
        set_at_path({:index, key}, value, data, opts)

      is_float(key) and is_list(data) ->
        set_at_path({:index, key}, value, data, opts)

      is_binary(key) and is_map(data) ->
        Map.put(data, key, value)

      is_nil(key) ->
        data

      true ->
        data
    end
  end

  defp set_at_path({:as, _bind_expr, _pattern, body}, value, data, opts) do
    # For assignment, `as` binding doesn't change the target path.
    # Just delegate to the body path.
    set_at_path(body, value, data, opts)
  end

  defp set_at_path({:func, :getpath, [path_expr]}, value, data, opts) do
    # getpath(p) |= v is equivalent to setpath(p, v)
    path = do_eval(path_expr, data, opts)

    Functions.eval_func(:setpath, [{:literal, path}, {:literal, value}], data, opts, __MODULE__)
  end

  defp set_at_path(path_expr, value, data, opts) do
    # For complex path expressions (user-defined functions, etc.),
    # use path-based assignment: compute all paths, then set each
    paths = Functions.eval_func(:path, [path_expr], data, opts, __MODULE__)

    path_list =
      case paths do
        {:multi, items} -> items
        :empty -> []
        item -> [item]
      end

    Enum.reduce(path_list, data, fn path, acc ->
      set_nested_path(acc, path, value)
    end)
  end

  # ======== Module System ========

  defp process_module_directives(directives, opts) do
    Enum.reduce(directives, opts, fn directive, acc_opts ->
      process_directive(directive, acc_opts)
    end)
  end

  defp process_directive({:module_meta, metadata}, opts) do
    Map.put(opts, :module_metadata, metadata)
  end

  defp process_directive({:import, path, alias_name, is_data, metadata}, opts) do
    if is_data do
      # Data import: import "data" as $d
      data = load_module_data(path, opts, metadata)
      var_name = String.trim_leading(alias_name, "$")
      # Store as a list (jq wraps data in an array)
      data_list = [data]
      bindings = Map.get(opts, :bindings, %{})
      opts = Map.put(opts, :bindings, Map.put(bindings, var_name, data_list))
      # Also store in data_namespaces for $d::d access
      data_ns = Map.get(opts, :data_namespaces, %{})
      Map.put(opts, :data_namespaces, Map.put(data_ns, var_name, %{var_name => data_list}))
    else
      # Function import: import "path" as name
      {funcs, _module_meta} = load_module_funcs(path, opts, metadata)
      namespaces = Map.get(opts, :namespaces, %{})
      # For import, functions are namespaced under alias_name
      # If namespace already exists, later imports shadow earlier ones per-function
      existing = Map.get(namespaces, alias_name, %{})
      merged = Map.merge(existing, funcs)
      Map.put(opts, :namespaces, Map.put(namespaces, alias_name, merged))
    end
  end

  defp process_directive({:include, path, metadata}, opts) do
    # Include: all definitions are added to current scope (no namespace)
    {funcs, _module_meta} = load_module_funcs(path, opts, metadata)
    user_funcs = Map.get(opts, :user_funcs, %{})
    # Include adds all functions directly to user_funcs
    merged = Map.merge(user_funcs, funcs)
    Map.put(opts, :user_funcs, merged)
  end

  defp load_module_data(path, opts, metadata) do
    file_path = resolve_module_path(path, opts, metadata, :data)

    case read_virtual_file(opts, file_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> data
          {:error, _} -> throw({:eval_error, "invalid JSON in data module: #{path}"})
        end

      {:error, reason} ->
        throw({:eval_error, "data module not found: #{path} (#{inspect(reason)})"})
    end
  end

  defp load_module_funcs(path, opts, metadata) do
    file_path = resolve_module_path(path, opts, metadata, :jq)

    case read_virtual_file(opts, file_path) do
      {:ok, content} ->
        # Set current_module_dir for relative imports within the module
        module_dir = Path.dirname(file_path)
        module_opts = Map.put(opts, :current_module_dir, module_dir)
        parse_module_file(content, path, module_opts, metadata)

      {:error, _} ->
        throw({:eval_error, "module not found: #{path} (searched: #{file_path})"})
    end
  end

  defp parse_module_file(content, _path, opts, _metadata) do
    # Module files may end with just definitions (no trailing expression).
    # Append ". " (identity) to ensure the parser has a body after the last def.
    content = String.trim(content)

    content =
      if String.ends_with?(content, ";") do
        content <> " ."
      else
        content
      end

    case Parser.parse(content) do
      {:ok, ast} ->
        extract_module_defs(ast, opts)

      {:error, reason} ->
        throw({:eval_error, "error parsing module: #{reason}"})
    end
  end

  defp extract_module_defs({:module_directives, directives, body}, opts) do
    # Process directives first (nested imports)
    opts = process_module_directives(directives, opts)
    # Extract module metadata from directives
    module_meta =
      Enum.find_value(directives, %{}, fn
        {:module_meta, meta} -> meta
        _ -> nil
      end) || %{}

    # Also collect dependency info for modulemeta
    deps =
      Enum.flat_map(directives, fn
        {:import, path, alias_name, is_data, metadata} ->
          # Strip leading "$" from data import aliases (jq convention)
          clean_alias = String.trim_leading(alias_name, "$")
          dep = %{"relpath" => path, "as" => clean_alias, "is_data" => is_data}

          dep =
            case Map.get(metadata, "search") do
              nil -> dep
              search -> Map.put(dep, "search", search)
            end

          [dep]

        _ ->
          []
      end)

    module_meta = Map.put(module_meta, :_deps, deps)

    {funcs, _} = extract_defs(body, opts, %{})
    {funcs, module_meta}
  end

  defp extract_module_defs(ast, opts) do
    {funcs, _} = extract_defs(ast, opts, %{})
    {funcs, %{}}
  end

  defp extract_defs({:def, name, params, body, after_def}, opts, acc) do
    arity = length(params)
    key = {name, arity}
    user_funcs = Map.get(opts, :user_funcs, %{})
    closure_funcs = Map.merge(user_funcs, acc)
    # Capture namespaces and bindings in closure for module functions
    func_def = %{
      params: params,
      body: body,
      closure_funcs: closure_funcs,
      self_key: key,
      closure_namespaces: Map.get(opts, :namespaces, %{}),
      closure_bindings: Map.get(opts, :bindings, %{}),
      closure_data_namespaces: Map.get(opts, :data_namespaces, %{})
    }

    acc = Map.put(acc, key, func_def)
    extract_defs(after_def, opts, acc)
  end

  defp extract_defs(_ast, _opts, acc) do
    {acc, nil}
  end

  defp resolve_module_path(path, opts, metadata, type) do
    module_paths = Map.get(opts, :module_paths, [])
    search = Map.get(metadata, "search", nil)
    current_dir = Map.get(opts, :current_module_dir, nil)

    # Build search paths
    search_paths =
      cond do
        search != nil and current_dir != nil ->
          [Path.expand(search, current_dir)]

        search != nil ->
          Enum.map(module_paths, fn mp -> Path.expand(search, mp) end)

        current_dir != nil ->
          # Search current module dir first, then global paths
          [current_dir | module_paths]

        true ->
          module_paths
      end

    ext = if type == :data, do: ".json", else: ".jq"

    # Try each search path
    Enum.find_value(search_paths, fn search_dir ->
      # Try direct file
      direct = Path.join(search_dir, path <> ext)

      if virtual_file_exists?(opts, direct) do
        direct
      else
        # Try directory/basename.jq pattern
        dir_file = Path.join([search_dir, path, Path.basename(path) <> ext])

        if virtual_file_exists?(opts, dir_file) do
          dir_file
        else
          nil
        end
      end
    end) ||
      throw({:eval_error, "module not found: #{path}"})
  end

  defp read_virtual_file(opts, path) do
    case Map.get(opts, :fs) do
      nil -> {:error, :no_fs}
      fs -> Fs.read_file(fs, path)
    end
  end

  defp virtual_file_exists?(opts, path) do
    case Map.get(opts, :fs) do
      nil -> false
      fs -> match?({:ok, _}, Fs.read_file(fs, path))
    end
  end
end
