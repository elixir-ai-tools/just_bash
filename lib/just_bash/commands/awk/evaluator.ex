defmodule JustBash.Commands.Awk.Evaluator do
  @moduledoc """
  Evaluator for AWK programs.

  Executes parsed AWK programs against input content, managing state
  and producing output.
  """

  alias JustBash.Commands.Awk.{Formatter, Parser}
  alias JustBash.Fs
  alias JustBash.Limit

  @type state :: %{
          nr: non_neg_integer(),
          nf: non_neg_integer(),
          fs: String.t(),
          ofs: String.t(),
          ors: String.t(),
          fields: [String.t()],
          variables: %{String.t() => String.t()},
          arrays: %{String.t() => map()},
          output: String.t(),
          exit_code: non_neg_integer() | nil
        }

  @doc """
  Execute an AWK program against the given content.

  Accepts opts with :files as a list of {filename, content} tuples for
  proper FNR/FILENAME multi-file support.

  Returns {output, exit_code, file_outputs, bash}.
  """
  @spec execute(Parser.program(), map()) ::
          {String.t(), non_neg_integer(), map(), JustBash.t() | nil}
  def execute(program, opts) do
    file_data = Map.get(opts, :files, [{"", ""}])

    state = %{
      nr: 0,
      nf: 0,
      fnr: 0,
      filename: "",
      fs: opts.field_separator,
      ofs: " ",
      ors: "\n",
      fields: [],
      variables: opts.variables,
      arrays: %{},
      output: "",
      exit_code: nil,
      file_outputs: %{},
      bash: Map.get(opts, :bash)
    }

    state = execute_begin_blocks(state, program.begin_blocks)

    state =
      if state.exit_code != nil do
        state
      else
        process_files(file_data, program.main_rules, state)
      end

    state =
      if state.exit_code != nil do
        state
      else
        execute_end_blocks(state, program.end_blocks)
      end

    {state.output, state.exit_code || 0, state.file_outputs, state.bash}
  end

  # Legacy 3-arity entry point for backward compatibility
  @spec execute(String.t(), Parser.program(), map()) ::
          {String.t(), non_neg_integer(), map(), JustBash.t() | nil}
  def execute(content, program, opts) do
    execute(program, Map.put(opts, :files, [{"", content}]))
  end

  defp process_files(file_data, rules, state) do
    Enum.reduce_while(file_data, state, fn {filename, content}, acc_state ->
      lines = split_content(content)
      acc_state = %{acc_state | fnr: 0, filename: filename}

      result =
        Enum.reduce_while(lines, acc_state, fn line, s ->
          new_state = process_line(line, rules, s)

          if new_state.exit_code != nil do
            {:halt, new_state}
          else
            {:cont, new_state}
          end
        end)

      if result.exit_code != nil do
        {:halt, result}
      else
        {:cont, result}
      end
    end)
  end

  defp split_content(content) do
    lines = String.split(content, "\n", trim: false)

    if List.last(lines) == "" do
      List.delete_at(lines, -1)
    else
      lines
    end
  end

  defp execute_begin_blocks(state, blocks) do
    Enum.reduce(blocks, state, fn statements, s ->
      execute_statements(statements, s)
    end)
  end

  defp execute_end_blocks(state, blocks) do
    Enum.reduce(blocks, state, fn statements, s ->
      execute_statements(statements, s)
    end)
  end

  defp process_line(line, rules, state) do
    fields = split_fields(line, state.fs)

    state = %{
      state
      | nr: state.nr + 1,
        fnr: state.fnr + 1,
        nf: length(fields),
        fields: [line | fields]
    }

    if rules == [] do
      state
    else
      apply_rules(rules, state)
    end
  end

  defp apply_rules([], state), do: state

  defp apply_rules([{pattern, action} | rest], state) do
    {matches, state} = pattern_matches?(pattern, state)

    if matches do
      case execute_statements_with_control(action, state) do
        {:next, new_state} ->
          # next: skip remaining rules for this line
          new_state

        new_state ->
          apply_rules(rest, new_state)
      end
    else
      apply_rules(rest, state)
    end
  end

  defp execute_statements_with_control(statements, state) do
    Enum.reduce_while(statements, state, fn stmt, acc_state ->
      case execute_statement(stmt, acc_state) do
        {:next, new_state} -> {:halt, {:next, new_state}}
        {:break, new_state} -> {:cont, new_state}
        {:continue, new_state} -> {:cont, new_state}
        new_state -> {:cont, new_state}
      end
    end)
  end

  defp split_fields(line, fs) do
    if fs == " " do
      String.split(line, ~r/\s+/, trim: true)
    else
      String.split(line, fs)
    end
  end

  defp pattern_matches?(nil, state), do: {true, state}

  defp pattern_matches?({:regex, pattern}, state) do
    result =
      case checked_compile(pattern, state) do
        {:ok, regex} -> Regex.match?(regex, Enum.at(state.fields, 0, ""))
        {:error, _} -> false
      end

    {result, state}
  end

  defp pattern_matches?({:condition, condition}, state) do
    evaluate_condition(condition, state)
  end

  defp evaluate_condition(condition, state) when is_binary(condition) do
    # String-based condition (from old parser) - use regex parsing
    result =
      case evaluate_nr_condition(condition, state) do
        nil -> evaluate_field_or_default(condition, state)
        result -> result
      end

    {result, state}
  end

  defp evaluate_condition(condition, state) when is_tuple(condition) do
    # AST-based condition (from new parser) - evaluate expression with side effects
    {value, state} = evaluate_expression_with_state(condition, state)
    {truthy?(value), state}
  end

  defp evaluate_field_or_default(condition, state) do
    case evaluate_field_condition(condition, state) do
      nil -> true
      result -> result
    end
  end

  defp evaluate_nr_condition(condition, state) do
    nr_patterns = [
      {~r/^NR\s*==\s*(\d+)$/, &==/2},
      {~r/^NR\s*>\s*(\d+)$/, &>/2},
      {~r/^NR\s*<\s*(\d+)$/, &</2},
      {~r/^NR\s*>=\s*(\d+)$/, &>=/2},
      {~r/^NR\s*<=\s*(\d+)$/, &<=/2}
    ]

    Enum.find_value(nr_patterns, fn {pattern, op} ->
      case Regex.run(pattern, condition) do
        [_, n] -> {:matched, op.(state.nr, String.to_integer(n))}
        nil -> nil
      end
    end)
    |> case do
      {:matched, result} -> result
      nil -> nil
    end
  end

  defp evaluate_field_condition(condition, state) do
    cond do
      condition =~ ~r/^\$(\d+)\s*==\s*"([^"]*)"$/ ->
        evaluate_field_equality(condition, state)

      condition =~ ~r/^\$(\d+)\s*~\s*\/([^\/]*)\/\s*$/ ->
        evaluate_field_regex(condition, state)

      # Numeric field comparisons: $1>5, $2>=10, etc.
      condition =~ ~r/^\$(\d+)\s*(==|!=|>=|<=|>|<)\s*(.+)$/ ->
        evaluate_field_numeric(condition, state)

      # Field vs variable comparison: $1>max
      condition =~ ~r/^\$(\w+)\s*(==|!=|>=|<=|>|<)\s*(\w+)$/ ->
        evaluate_field_vs_var(condition, state)

      true ->
        nil
    end
  end

  defp evaluate_field_equality(condition, state) do
    [_, field_str, value] = Regex.run(~r/^\$(\d+)\s*==\s*"([^"]*)"$/, condition)
    field = String.to_integer(field_str)
    get_field(state, field) == value
  end

  defp evaluate_field_regex(condition, state) do
    [_, field_str, pattern] = Regex.run(~r/^\$(\d+)\s*~\s*\/([^\/]*)\/\s*$/, condition)
    field = String.to_integer(field_str)
    field_value = get_field(state, field)

    case checked_compile(pattern, state) do
      {:ok, regex} -> Regex.match?(regex, field_value)
      {:error, _} -> false
    end
  end

  defp evaluate_field_numeric(condition, state) do
    [_, field_str, op, right_str] = Regex.run(~r/^\$(\d+)\s*(==|!=|>=|<=|>|<)\s*(.+)$/, condition)
    field = String.to_integer(field_str)
    left_val = get_field(state, field) |> parse_number()

    # right_str could be a number or a variable name
    right_val =
      cond do
        right_str =~ ~r/^-?\d+(\.\d+)?$/ ->
          parse_number(right_str)

        Map.has_key?(state.variables, right_str) ->
          Map.get(state.variables, right_str) |> parse_number()

        true ->
          parse_number(right_str)
      end

    apply_comparison(op, left_val, right_val)
  end

  defp evaluate_field_vs_var(condition, state) do
    [_, field_str, op, var_name] = Regex.run(~r/^\$(\w+)\s*(==|!=|>=|<=|>|<)\s*(\w+)$/, condition)

    # Get field value
    left_val =
      case Integer.parse(field_str) do
        {n, ""} -> get_field(state, n) |> parse_number()
        _ -> get_field(state, 0) |> parse_number()
      end

    # Get variable value
    right_val =
      case Map.get(state.variables, var_name) do
        nil -> 0.0
        v -> parse_number(v)
      end

    apply_comparison(op, left_val, right_val)
  end

  defp apply_comparison("==", left, right), do: left == right
  defp apply_comparison("!=", left, right), do: left != right
  defp apply_comparison(">", left, right), do: left > right
  defp apply_comparison("<", left, right), do: left < right
  defp apply_comparison(">=", left, right), do: left >= right
  defp apply_comparison("<=", left, right), do: left <= right

  defp execute_statements(statements, state) do
    Enum.reduce(statements, state, &execute_statement/2)
  end

  defp execute_statement(nil, state), do: state

  defp execute_statement(%{statements: stmts}, state) do
    Enum.reduce_while(stmts, state, fn stmt, acc_state ->
      case execute_statement(stmt, acc_state) do
        {:next, _} = signal -> {:halt, signal}
        {:break, _} = signal -> {:halt, signal}
        {:continue, _} = signal -> {:halt, signal}
        new_state -> {:cont, new_state}
      end
    end)
  end

  defp execute_statement({:print, {:comma_sep, args}}, state) do
    # Comma-separated: use OFS between values
    {values, state} =
      Enum.map_reduce(args, state, fn arg, acc_state ->
        evaluate_expression_with_state(arg, acc_state)
      end)

    formatted = Enum.map(values, &format_output_value/1)
    output_line = Enum.join(formatted, state.ofs) <> state.ors
    %{state | output: state.output <> output_line}
  end

  defp execute_statement({:print, {:concat, args}}, state) do
    # Space-separated in source: concatenate without separator
    {values, state} =
      Enum.map_reduce(args, state, fn arg, acc_state ->
        evaluate_expression_with_state(arg, acc_state)
      end)

    formatted = Enum.map(values, &format_output_value/1)
    output_line = Enum.join(formatted, "") <> state.ors
    %{state | output: state.output <> output_line}
  end

  defp execute_statement({:print, args}, state) when is_list(args) do
    # Legacy format - treat as comma-separated for backward compatibility
    {values, state} =
      Enum.map_reduce(args, state, fn arg, acc_state ->
        evaluate_expression_with_state(arg, acc_state)
      end)

    formatted = Enum.map(values, &format_output_value/1)
    output_line = Enum.join(formatted, state.ofs) <> state.ors
    %{state | output: state.output <> output_line}
  end

  defp execute_statement({:printf, {format, args}}, state) do
    values = Enum.map(args, &evaluate_expression(&1, state))
    output = Formatter.format_printf(format, values)
    %{state | output: state.output <> output}
  end

  # Print/printf with output redirection to file (> and >>)
  defp execute_statement({:print_redirect, {:comma_sep, args}, file_expr}, state) do
    {values, state} =
      Enum.map_reduce(args, state, fn arg, acc_state ->
        evaluate_expression_with_state(arg, acc_state)
      end)

    filename = evaluate_expression(file_expr, state) |> to_string()
    formatted = Enum.map(values, &format_output_value/1)
    output_line = Enum.join(formatted, state.ofs) <> state.ors
    # Overwrite: replace file content (but accumulate within same program run)
    existing = Map.get(state.file_outputs, filename, "")
    %{state | file_outputs: Map.put(state.file_outputs, filename, existing <> output_line)}
  end

  defp execute_statement({:print_append, {:comma_sep, args}, file_expr}, state) do
    {values, state} =
      Enum.map_reduce(args, state, fn arg, acc_state ->
        evaluate_expression_with_state(arg, acc_state)
      end)

    filename = evaluate_expression(file_expr, state) |> to_string()
    formatted = Enum.map(values, &format_output_value/1)
    output_line = Enum.join(formatted, state.ofs) <> state.ors
    existing = Map.get(state.file_outputs, filename, "")
    %{state | file_outputs: Map.put(state.file_outputs, filename, existing <> output_line)}
  end

  defp execute_statement({:printf_redirect, {format, args}, file_expr}, state) do
    values = Enum.map(args, &evaluate_expression(&1, state))
    filename = evaluate_expression(file_expr, state) |> to_string()
    output = Formatter.format_printf(format, values)
    existing = Map.get(state.file_outputs, filename, "")
    %{state | file_outputs: Map.put(state.file_outputs, filename, existing <> output)}
  end

  defp execute_statement({:printf_append, {format, args}, file_expr}, state) do
    values = Enum.map(args, &evaluate_expression(&1, state))
    filename = evaluate_expression(file_expr, state) |> to_string()
    output = Formatter.format_printf(format, values)
    existing = Map.get(state.file_outputs, filename, "")
    %{state | file_outputs: Map.put(state.file_outputs, filename, existing <> output)}
  end

  defp execute_statement({:field_assign, index_expr, value_expr}, state) do
    idx = evaluate_expression(index_expr, state) |> parse_number() |> round()
    {raw_value, state} = evaluate_expression_with_state(value_expr, state)
    value = to_string(raw_value)

    # fields is [entire_line, field1, field2, ...]
    # field N (1-based) is at index N in the list
    current_fields = state.fields
    nf = state.nf

    if idx < 0 do
      state
    else
      # Ensure the fields list is long enough (pad with empty strings)
      new_nf = max(nf, idx)

      padded_fields =
        if length(current_fields) <= new_nf do
          current_fields ++ List.duplicate("", new_nf + 1 - length(current_fields))
        else
          current_fields
        end

      # Replace field at index idx (1-based, so list index idx)
      updated_fields = List.replace_at(padded_fields, idx, value)

      # Reconstruct $0 from fields 1..new_nf joined by OFS
      new_record = Enum.slice(updated_fields, 1, new_nf) |> Enum.join(state.ofs)
      final_fields = List.replace_at(updated_fields, 0, new_record)

      %{state | fields: final_fields, nf: new_nf}
    end
  end

  defp execute_statement({:assign, var, expr}, state) do
    {raw_value, state} = evaluate_expression_with_state(expr, state)
    value = to_string(raw_value)

    # Handle special variables
    case var do
      "OFS" -> %{state | ofs: value}
      "ORS" -> %{state | ors: value}
      "FS" -> %{state | fs: value}
      _ -> %{state | variables: Map.put(state.variables, var, value)}
    end
  end

  defp execute_statement({:add_assign, var, expr}, state) do
    current = Map.get(state.variables, var, "0")
    current_num = parse_number(current)
    add_val = evaluate_expression(expr, state) |> parse_number()
    new_val = current_num + add_val
    %{state | variables: Map.put(state.variables, var, to_string(new_val))}
  end

  defp execute_statement({:increment, var}, state) do
    current = Map.get(state.variables, var, "0")
    current_num = parse_number(current)
    %{state | variables: Map.put(state.variables, var, to_string(current_num + 1))}
  end

  defp execute_statement({:pre_increment, var}, state) do
    current = Map.get(state.variables, var, "0")
    current_num = parse_number(current)
    %{state | variables: Map.put(state.variables, var, to_string(current_num + 1))}
  end

  defp execute_statement({:decrement, var}, state) do
    current = Map.get(state.variables, var, "0")
    current_num = parse_number(current)
    %{state | variables: Map.put(state.variables, var, to_string(current_num - 1))}
  end

  defp execute_statement({:pre_decrement, var}, state) do
    current = Map.get(state.variables, var, "0")
    current_num = parse_number(current)
    %{state | variables: Map.put(state.variables, var, to_string(current_num - 1))}
  end

  defp execute_statement({:sub_assign, var, expr}, state) do
    current = Map.get(state.variables, var, "0")
    current_num = parse_number(current)
    sub_val = evaluate_expression(expr, state) |> parse_number()
    new_val = current_num - sub_val
    %{state | variables: Map.put(state.variables, var, to_string(new_val))}
  end

  defp execute_statement({:mul_assign, var, expr}, state) do
    current = Map.get(state.variables, var, "1")
    current_num = parse_number(current)
    mul_val = evaluate_expression(expr, state) |> parse_number()
    new_val = current_num * mul_val
    %{state | variables: Map.put(state.variables, var, to_string(new_val))}
  end

  defp execute_statement({:div_assign, var, expr}, state) do
    current = Map.get(state.variables, var, "0")
    current_num = parse_number(current)
    div_val = evaluate_expression(expr, state) |> parse_number()
    new_val = if div_val == 0, do: 0.0, else: current_num / div_val
    %{state | variables: Map.put(state.variables, var, to_string(new_val))}
  end

  # Array operations
  defp execute_statement({:array_assign, array, key_expr, value_expr}, state) do
    {key, state} = evaluate_expression_with_state(key_expr, state)
    key = format_array_key(key)
    value = evaluate_expression(value_expr, state) |> to_string()
    arr = Map.get(state.arrays, array, %{})
    new_arr = Map.put(arr, key, value)
    %{state | arrays: Map.put(state.arrays, array, new_arr)}
  end

  defp execute_statement({:array_increment, array, key_expr}, state) do
    key = evaluate_expression(key_expr, state) |> format_array_key()
    arr = Map.get(state.arrays, array, %{})
    current = Map.get(arr, key, "0") |> parse_number()
    new_arr = Map.put(arr, key, to_string(current + 1))
    %{state | arrays: Map.put(state.arrays, array, new_arr)}
  end

  defp execute_statement({:array_add_assign, array, key_expr, value_expr}, state) do
    key = evaluate_expression(key_expr, state) |> format_array_key()
    value = evaluate_expression(value_expr, state) |> parse_number()
    arr = Map.get(state.arrays, array, %{})
    current = Map.get(arr, key, "0") |> parse_number()
    new_arr = Map.put(arr, key, to_string(current + value))
    %{state | arrays: Map.put(state.arrays, array, new_arr)}
  end

  defp execute_statement({:delete_element, array, key_expr}, state) do
    key = evaluate_expression(key_expr, state) |> format_array_key()
    arr = Map.get(state.arrays, array, %{})
    new_arr = Map.delete(arr, key)
    %{state | arrays: Map.put(state.arrays, array, new_arr)}
  end

  defp execute_statement({:delete_array, array}, state) do
    %{state | arrays: Map.delete(state.arrays, array)}
  end

  # Control flow
  defp execute_statement({:break}, state), do: {:break, state}
  defp execute_statement({:continue}, state), do: {:continue, state}
  defp execute_statement({:next}, state), do: {:next, state}

  defp execute_statement({:exit, code}, state) when is_number(code) do
    %{state | exit_code: trunc(code)}
  end

  defp execute_statement({:exit, code}, state) do
    evaluated = evaluate_expression(code, state) |> parse_number() |> trunc()
    %{state | exit_code: evaluated}
  end

  # For loop
  defp execute_statement({:for, init, cond_expr, update, body}, state) do
    # Execute init
    state = if init, do: execute_statement(init, state), else: state
    execute_for_loop(cond_expr, update, body, state)
  end

  # For-in loop (iterate over array keys)
  defp execute_statement({:for_in, var, array, body}, state) do
    arr = Map.get(state.arrays, array, %{})
    keys = Map.keys(arr)

    Enum.reduce_while(keys, state, fn key, acc_state ->
      new_state = %{acc_state | variables: Map.put(acc_state.variables, var, key)}

      case execute_loop_body(body, new_state) do
        {:break, final_state} -> {:halt, final_state}
        {:continue, final_state} -> {:cont, final_state}
        final_state -> {:cont, final_state}
      end
    end)
  end

  # While loop
  defp execute_statement({:while, cond_expr, body}, state) do
    execute_while_loop(cond_expr, body, state)
  end

  # Do-while loop
  defp execute_statement({:do_while, body, cond_expr}, state) do
    execute_do_while_loop(body, cond_expr, state)
  end

  # if (condition) then_stmt; else else_stmt
  defp execute_statement({:if, condition, then_stmt, else_stmt}, state) do
    if evaluate_condition_expr(condition, state) do
      execute_statement(then_stmt, state)
    else
      if else_stmt do
        execute_statement(else_stmt, state)
      else
        state
      end
    end
  end

  # gsub(/pattern/, "replacement", target) - replace all occurrences
  defp execute_statement({:gsub, pattern, replacement, {:field, 0}}, state) do
    line = Enum.at(state.fields, 0, "")

    case checked_compile(pattern, state) do
      {:ok, regex} ->
        new_line = Regex.replace(regex, line, replacement)
        new_fields = [new_line | tl(state.fields)]
        %{state | fields: new_fields}

      {:error, _} ->
        state
    end
  end

  defp execute_statement({:gsub, pattern, replacement, {:field, n}}, state) do
    field_val = Enum.at(state.fields, n, "")

    case checked_compile(pattern, state) do
      {:ok, regex} ->
        new_val = Regex.replace(regex, field_val, replacement)
        new_fields = List.replace_at(state.fields, n, new_val)
        %{state | fields: new_fields}

      {:error, _} ->
        state
    end
  end

  defp execute_statement({:gsub, pattern, replacement, {:variable, var}}, state) do
    current = Map.get(state.variables, var, "")

    case checked_compile(pattern, state) do
      {:ok, regex} ->
        new_val = Regex.replace(regex, current, replacement)
        %{state | variables: Map.put(state.variables, var, new_val)}

      {:error, _} ->
        state
    end
  end

  # sub(/pattern/, "replacement", target) - replace first occurrence only
  defp execute_statement({:sub, pattern, replacement, {:field, 0}}, state) do
    line = Enum.at(state.fields, 0, "")

    case checked_compile(pattern, state) do
      {:ok, regex} ->
        new_line = Regex.replace(regex, line, replacement, global: false)
        new_fields = [new_line | tl(state.fields)]
        %{state | fields: new_fields}

      {:error, _} ->
        state
    end
  end

  defp execute_statement({:sub, pattern, replacement, {:field, n}}, state) do
    field_val = Enum.at(state.fields, n, "")

    case checked_compile(pattern, state) do
      {:ok, regex} ->
        new_val = Regex.replace(regex, field_val, replacement, global: false)
        new_fields = List.replace_at(state.fields, n, new_val)
        %{state | fields: new_fields}

      {:error, _} ->
        state
    end
  end

  defp execute_statement({:sub, pattern, replacement, {:variable, var}}, state) do
    current = Map.get(state.variables, var, "")

    case checked_compile(pattern, state) do
      {:ok, regex} ->
        new_val = Regex.replace(regex, current, replacement, global: false)
        %{state | variables: Map.put(state.variables, var, new_val)}

      {:error, _} ->
        state
    end
  end

  # Handle gsub/sub as function calls (new parser format)
  defp execute_statement({:call, "gsub", args}, state) do
    {pattern, replacement, target} = extract_gsub_args(args, state)
    execute_statement({:gsub, pattern, replacement, target}, state)
  end

  defp execute_statement({:call, "sub", args}, state) do
    {pattern, replacement, target} = extract_gsub_args(args, state)
    execute_statement({:sub, pattern, replacement, target}, state)
  end

  # Handle getline as statement
  defp execute_statement({:getline, _var, _file, _pipe} = expr, state) do
    {_result, state} = evaluate_expression_with_state(expr, state)
    state
  end

  # Handle match() as statement (needs state for RSTART/RLENGTH and optional array)
  defp execute_statement({:call, "match", args}, state) do
    {_result, state} = execute_match(args, state)
    state
  end

  defp execute_statement({:call, "system", [cmd_expr]}, state) do
    cmd = evaluate_expression(cmd_expr, state) |> to_string()
    {exit_code, state} = execute_system_command(cmd, state)
    # Store result in case it's also used as expression via evaluate_expression_with_state
    %{state | variables: Map.put(state.variables, "__system_rc__", to_string(exit_code))}
  end

  # Handle split() as statement (needs to populate array in state)
  defp execute_statement({:call, "split", args}, state) do
    {_count, state} = execute_split(args, state)
    state
  end

  # Handle asorti() as statement
  defp execute_statement({:call, "asorti", args}, state) do
    {_count, state} = execute_asorti(args, state)
    state
  end

  # Generic catch-all for function calls as statements (e.g., close(), delete())
  defp execute_statement({:call, name, args}, state) do
    {_result, state} = evaluate_expression_with_state({:call, name, args}, state)
    state
  end

  # match(string, regex [, array]) implementation
  defp execute_match(args, state) do
    {string, pattern, array_name} = extract_match_args(args, state)
    regex = compile_awk_regex(pattern, state)

    case Regex.run(regex, string, return: :index) do
      nil ->
        vars = state.variables |> Map.put("RSTART", "0") |> Map.put("RLENGTH", "-1")
        {0, %{state | variables: vars}}

      [{start, len} | group_indices] ->
        rstart = start + 1

        vars =
          state.variables
          |> Map.put("RSTART", to_string(rstart))
          |> Map.put("RLENGTH", to_string(len))

        state = %{state | variables: vars}

        state =
          case array_name do
            nil ->
              state

            name ->
              # Populate array: index 0 = full match, 1..n = capture groups
              full_match = String.slice(string, start, len)
              arr = %{"0" => full_match}

              arr =
                group_indices
                |> Enum.with_index(1)
                |> Enum.reduce(arr, fn {{gs, gl}, idx}, acc ->
                  Map.put(acc, to_string(idx), String.slice(string, gs, gl))
                end)

              %{state | arrays: Map.put(state.arrays, name, arr)}
          end

        {rstart, state}
    end
  end

  defp extract_match_args([str_expr, {:regex, pattern}], state) do
    {to_string(evaluate_expression(str_expr, state)), pattern, nil}
  end

  defp extract_match_args([str_expr, {:regex, pattern}, {:variable, name}], state) do
    {to_string(evaluate_expression(str_expr, state)), pattern, name}
  end

  defp extract_match_args([str_expr, pat_expr], state) do
    {to_string(evaluate_expression(str_expr, state)),
     to_string(evaluate_expression(pat_expr, state)), nil}
  end

  defp extract_match_args([str_expr, pat_expr, {:variable, name}], state) do
    {to_string(evaluate_expression(str_expr, state)),
     to_string(evaluate_expression(pat_expr, state)), name}
  end

  # split(string, array [, separator]) - splits string into array, returns count
  defp execute_split(args, state) do
    {str, array_name, sep} = extract_split_args(args, state)
    parts = String.split(str, sep)

    arr =
      parts
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {part, idx}, acc ->
        Map.put(acc, to_string(idx), part)
      end)

    state = %{state | arrays: Map.put(state.arrays, array_name, arr)}
    {length(parts), state}
  end

  # asorti(source, dest) - sorts indices of source into dest[1], dest[2], ...
  defp execute_asorti(args, state) do
    {source_name, dest_name} = extract_asorti_args(args)
    source = Map.get(state.arrays, source_name, %{})
    sorted_keys = source |> Map.keys() |> Enum.sort()

    dest =
      sorted_keys
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {key, idx}, acc ->
        Map.put(acc, to_string(idx), key)
      end)

    state = %{state | arrays: Map.put(state.arrays, dest_name, dest)}
    {length(sorted_keys), state}
  end

  defp extract_asorti_args([{:variable, source}, {:variable, dest}]), do: {source, dest}
  defp extract_asorti_args([{:literal, source}, {:variable, dest}]), do: {source, dest}
  defp extract_asorti_args([{:variable, source}, {:literal, dest}]), do: {source, dest}
  defp extract_asorti_args([{:literal, source}, {:literal, dest}]), do: {source, dest}

  defp extract_split_args([str_expr, {:variable, array_name}, sep_expr], state) do
    str = evaluate_expression(str_expr, state) |> to_string()
    sep = evaluate_expression(sep_expr, state) |> to_string()
    {str, array_name, sep}
  end

  defp extract_split_args([str_expr, {:variable, array_name}], state) do
    str = evaluate_expression(str_expr, state) |> to_string()
    {str, array_name, state.fs}
  end

  defp extract_split_args([str_expr, {:literal, array_name}, sep_expr], state) do
    str = evaluate_expression(str_expr, state) |> to_string()
    sep = evaluate_expression(sep_expr, state) |> to_string()
    {str, array_name, sep}
  end

  defp extract_split_args([str_expr, {:literal, array_name}], state) do
    str = evaluate_expression(str_expr, state) |> to_string()
    {str, array_name, state.fs}
  end

  defp checked_compile(pattern, state) do
    limits = if state.bash, do: state.bash.limits
    Limit.compile_regex(limits, pattern)
  end

  defp compile_awk_regex(pattern, state) do
    case checked_compile(pattern, state) do
      {:ok, regex} -> regex
      {:error, _} -> ~r/(?!)/
    end
  end

  defp extract_gsub_args([{:regex, pattern}, replacement], _state) do
    {pattern, extract_string(replacement), {:field, 0}}
  end

  defp extract_gsub_args([{:regex, pattern}, replacement, target], _state) do
    {pattern, extract_string(replacement), target}
  end

  defp extract_gsub_args([pattern, replacement], state) do
    {extract_string_value(pattern, state), extract_string(replacement), {:field, 0}}
  end

  defp extract_gsub_args([pattern, replacement, target], state) do
    {extract_string_value(pattern, state), extract_string(replacement), target}
  end

  defp extract_string({:literal, s}), do: s
  defp extract_string({:string, s}), do: s
  defp extract_string(s) when is_binary(s), do: s
  defp extract_string(other), do: to_string(other)

  defp unwrap_pattern({:regex, p}), do: p
  defp unwrap_pattern(p) when is_binary(p), do: p
  defp unwrap_pattern(other), do: to_string(other)

  defp extract_string_value(expr, state) do
    evaluate_expression(expr, state) |> to_string()
  end

  # Loop helper functions

  defp execute_for_loop(cond_expr, update, body, state) do
    if truthy?(evaluate_expression(cond_expr, state)) do
      case execute_loop_body(body, state) do
        {:break, new_state} ->
          new_state

        {:continue, new_state} ->
          new_state = if update, do: execute_statement(update, new_state), else: new_state
          execute_for_loop(cond_expr, update, body, new_state)

        new_state ->
          new_state = if update, do: execute_statement(update, new_state), else: new_state
          execute_for_loop(cond_expr, update, body, new_state)
      end
    else
      state
    end
  end

  defp execute_while_loop(cond_expr, body, state) do
    {cond_val, state} = evaluate_condition_with_state(cond_expr, state)

    if truthy?(cond_val) do
      case execute_loop_body(body, state) do
        {:break, new_state} ->
          new_state

        {:continue, new_state} ->
          execute_while_loop(cond_expr, body, new_state)

        new_state ->
          execute_while_loop(cond_expr, body, new_state)
      end
    else
      state
    end
  end

  # Evaluate condition while threading state (needed for getline in while conditions)
  defp evaluate_condition_with_state({:>, left, right}, state) do
    {left_val, state} = evaluate_expression_with_state(left, state)
    {right_val, state} = evaluate_expression_with_state(right, state)
    result = if parse_number(left_val) > parse_number(right_val), do: 1, else: 0
    {result, state}
  end

  defp evaluate_condition_with_state(expr, state) do
    {evaluate_expression(expr, state), state}
  end

  defp execute_do_while_loop(body, cond_expr, state) do
    case execute_loop_body(body, state) do
      {:break, new_state} ->
        new_state

      {:continue, new_state} ->
        if truthy?(evaluate_expression(cond_expr, new_state)) do
          execute_do_while_loop(body, cond_expr, new_state)
        else
          new_state
        end

      new_state ->
        if truthy?(evaluate_expression(cond_expr, new_state)) do
          execute_do_while_loop(body, cond_expr, new_state)
        else
          new_state
        end
    end
  end

  defp execute_loop_body(statements, state) do
    Enum.reduce_while(statements, state, fn stmt, acc_state ->
      case execute_statement(stmt, acc_state) do
        {:break, new_state} -> {:halt, {:break, new_state}}
        {:continue, new_state} -> {:halt, {:continue, new_state}}
        new_state -> {:cont, new_state}
      end
    end)
  end

  @doc """
  Evaluate an expression in the given state context.
  """
  @spec evaluate_expression(Parser.expr(), state()) :: String.t() | number()
  def evaluate_expression({:literal, value}, _state), do: value
  def evaluate_expression({:number, value}, _state), do: value
  def evaluate_expression({:field, n}, state), do: get_field(state, n)

  def evaluate_expression({:field_var, var_name}, state) do
    n =
      case var_name do
        "NF" ->
          state.nf

        "NR" ->
          state.nr

        "FNR" ->
          Map.get(state, :fnr, state.nr)

        _ ->
          case Map.get(state.variables, var_name) do
            nil -> 0
            v -> parse_number(v) |> trunc()
          end
      end

    get_field(state, n)
  end

  def evaluate_expression({:variable, "NR"}, state), do: state.nr
  def evaluate_expression({:variable, "NF"}, state), do: state.nf
  def evaluate_expression({:variable, "FNR"}, state), do: Map.get(state, :fnr, state.nr)
  def evaluate_expression({:variable, "FILENAME"}, state), do: Map.get(state, :filename, "")
  def evaluate_expression({:variable, "FS"}, state), do: state.fs
  def evaluate_expression({:variable, "OFS"}, state), do: state.ofs
  def evaluate_expression({:variable, "ORS"}, state), do: state.ors

  def evaluate_expression({:variable, name}, state) do
    Map.get(state.variables, name, "")
  end

  def evaluate_expression({:add, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()
    left_val + right_val
  end

  # String concatenation (binary form)
  def evaluate_expression({:concat, left, right}, state) do
    left_val = evaluate_expression(left, state) |> to_string()
    right_val = evaluate_expression(right, state) |> to_string()
    left_val <> right_val
  end

  # Ternary operator
  def evaluate_expression({:ternary, condition, true_expr, false_expr}, state) do
    if evaluate_condition_expr(condition, state) do
      evaluate_expression(true_expr, state)
    else
      evaluate_expression(false_expr, state)
    end
  end

  # Function calls
  def evaluate_expression({:call, name, args}, state) do
    evaluated_args = Enum.map(args, &evaluate_expression(&1, state))
    evaluate_function(name, evaluated_args, state)
  end

  def evaluate_expression({:sub, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()
    left_val - right_val
  end

  def evaluate_expression({:mul, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()
    left_val * right_val
  end

  def evaluate_expression({:div, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()

    if right_val == 0 do
      0.0
    else
      left_val / right_val
    end
  end

  # Modulo
  def evaluate_expression({:mod, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number() |> trunc()
    right_val = evaluate_expression(right, state) |> parse_number() |> trunc()

    if right_val == 0 do
      0
    else
      rem(left_val, right_val)
    end
  end

  # Power
  def evaluate_expression({:pow, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()
    :math.pow(left_val, right_val)
  end

  # Logical operators
  def evaluate_expression({:and, left, right}, state) do
    left_val = evaluate_expression(left, state)

    if truthy?(left_val) do
      right_val = evaluate_expression(right, state)
      if truthy?(right_val), do: 1, else: 0
    else
      0
    end
  end

  def evaluate_expression({:or, left, right}, state) do
    left_val = evaluate_expression(left, state)

    if truthy?(left_val) do
      1
    else
      right_val = evaluate_expression(right, state)
      if truthy?(right_val), do: 1, else: 0
    end
  end

  def evaluate_expression({:not, expr}, state) do
    val = evaluate_expression(expr, state)
    if truthy?(val), do: 0, else: 1
  end

  # /regex/ as expression matches against $0 (equivalent to $0 ~ /regex/)
  def evaluate_expression({:regex, pattern}, state) do
    line = get_field(state, 0)

    case checked_compile(pattern, state) do
      {:ok, re} -> if Regex.match?(re, line), do: 1, else: 0
      _ -> 0
    end
  end

  # Unary minus
  def evaluate_expression({:negate, expr}, state) do
    val = evaluate_expression(expr, state) |> parse_number()
    -val
  end

  # Comparison operators as expressions (return 0 or 1)
  def evaluate_expression({:==, left, right}, state) do
    left_val = evaluate_expression(left, state)
    right_val = evaluate_expression(right, state)
    if compare_values(left_val, right_val, &==/2), do: 1, else: 0
  end

  def evaluate_expression({:!=, left, right}, state) do
    left_val = evaluate_expression(left, state)
    right_val = evaluate_expression(right, state)
    if compare_values(left_val, right_val, &!=/2), do: 1, else: 0
  end

  def evaluate_expression({:>, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()
    if left_val > right_val, do: 1, else: 0
  end

  def evaluate_expression({:<, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()
    if left_val < right_val, do: 1, else: 0
  end

  def evaluate_expression({:>=, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()
    if left_val >= right_val, do: 1, else: 0
  end

  def evaluate_expression({:<=, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()
    if left_val <= right_val, do: 1, else: 0
  end

  # Regex match as expression
  def evaluate_expression({:match, expr, pattern}, state) do
    value = evaluate_expression(expr, state) |> to_string()
    pattern_str = unwrap_pattern(pattern)

    case checked_compile(pattern_str, state) do
      {:ok, regex} -> if Regex.match?(regex, value), do: 1, else: 0
      {:error, _} -> 0
    end
  end

  def evaluate_expression({:not_match, expr, pattern}, state) do
    value = evaluate_expression(expr, state) |> to_string()
    pattern_str = unwrap_pattern(pattern)

    case checked_compile(pattern_str, state) do
      {:ok, regex} -> if Regex.match?(regex, value), do: 0, else: 1
      {:error, _} -> 1
    end
  end

  # "in" operator: key in array
  def evaluate_expression({:in, key_expr, array_name}, state) do
    key = evaluate_expression(key_expr, state) |> format_array_key()
    arr = Map.get(state.arrays, array_name, %{})
    if Map.has_key?(arr, key), do: 1, else: 0
  end

  # Increment/decrement as expressions (without state propagation - for backward compatibility)
  def evaluate_expression({:increment, var}, state) do
    # Post-increment: returns current value (side effect lost without state return)
    current = Map.get(state.variables, var, "0")
    parse_number(current)
  end

  def evaluate_expression({:pre_increment, var}, state) do
    # Pre-increment: returns incremented value (side effect lost without state return)
    current = Map.get(state.variables, var, "0")
    parse_number(current) + 1
  end

  def evaluate_expression({:decrement, var}, state) do
    current = Map.get(state.variables, var, "0")
    parse_number(current)
  end

  def evaluate_expression({:pre_decrement, var}, state) do
    current = Map.get(state.variables, var, "0")
    parse_number(current) - 1
  end

  # Array element increment/decrement as expressions
  def evaluate_expression({:array_increment, array, key_expr}, state) do
    key = evaluate_expression(key_expr, state) |> to_string()
    arr = Map.get(state.arrays, array, %{})
    Map.get(arr, key, "0") |> parse_number()
  end

  def evaluate_expression({:array_pre_increment, array, key_expr}, state) do
    key = evaluate_expression(key_expr, state) |> to_string()
    arr = Map.get(state.arrays, array, %{})
    Map.get(arr, key, "0") |> parse_number() |> Kernel.+(1)
  end

  def evaluate_expression({:array_decrement, array, key_expr}, state) do
    key = evaluate_expression(key_expr, state) |> to_string()
    arr = Map.get(state.arrays, array, %{})
    Map.get(arr, key, "0") |> parse_number()
  end

  def evaluate_expression({:array_pre_decrement, array, key_expr}, state) do
    key = evaluate_expression(key_expr, state) |> to_string()
    arr = Map.get(state.arrays, array, %{})
    Map.get(arr, key, "0") |> parse_number() |> Kernel.-(1)
  end

  # Array access
  def evaluate_expression({:array_access, array_name, key_expr}, state) do
    raw_key = evaluate_expression(key_expr, state)
    key = format_array_key(raw_key)
    arr = Map.get(state.arrays, array_name, %{})
    Map.get(arr, key, "")
  end

  # Defensive catch-all: unknown AST shapes return an empty string rather than
  # crashing the whole bash process. Real awk would raise a syntax error at
  # parse time; we'd rather keep the shell alive and let the user see nothing.
  def evaluate_expression(_unknown, _state), do: ""

  @doc """
  Evaluate an expression and return both the value and potentially updated state.
  Most expressions don't modify state, but increment/decrement expressions do.
  """
  def evaluate_expression_with_state({:increment, var}, state) do
    current = Map.get(state.variables, var, "0")
    current_num = parse_number(current)
    new_state = %{state | variables: Map.put(state.variables, var, to_string(current_num + 1))}
    {current_num, new_state}
  end

  def evaluate_expression_with_state({:pre_increment, var}, state) do
    current = Map.get(state.variables, var, "0")
    current_num = parse_number(current) + 1
    new_state = %{state | variables: Map.put(state.variables, var, to_string(current_num))}
    {current_num, new_state}
  end

  def evaluate_expression_with_state({:decrement, var}, state) do
    current = Map.get(state.variables, var, "0")
    current_num = parse_number(current)
    new_state = %{state | variables: Map.put(state.variables, var, to_string(current_num - 1))}
    {current_num, new_state}
  end

  def evaluate_expression_with_state({:pre_decrement, var}, state) do
    current = Map.get(state.variables, var, "0")
    current_num = parse_number(current) - 1
    new_state = %{state | variables: Map.put(state.variables, var, to_string(current_num))}
    {current_num, new_state}
  end

  # Logical not with potential side effects in subexpression
  def evaluate_expression_with_state({:not, expr}, state) do
    {val, state} = evaluate_expression_with_state(expr, state)
    result = if truthy?(val), do: 0, else: 1
    {result, state}
  end

  # Array element post-increment: arr[key]++ — returns old value, then increments
  def evaluate_expression_with_state({:array_increment, array, key_expr}, state) do
    key = evaluate_expression(key_expr, state) |> format_array_key()
    arr = Map.get(state.arrays, array, %{})
    current = Map.get(arr, key, "0") |> parse_number()
    new_arr = Map.put(arr, key, to_string(current + 1))
    new_state = %{state | arrays: Map.put(state.arrays, array, new_arr)}
    {current, new_state}
  end

  # Array element pre-increment: ++arr[key] — increments, then returns new value
  def evaluate_expression_with_state({:array_pre_increment, array, key_expr}, state) do
    key = evaluate_expression(key_expr, state) |> format_array_key()
    arr = Map.get(state.arrays, array, %{})
    current = Map.get(arr, key, "0") |> parse_number()
    new_val = current + 1
    new_arr = Map.put(arr, key, to_string(new_val))
    new_state = %{state | arrays: Map.put(state.arrays, array, new_arr)}
    {new_val, new_state}
  end

  # Array element post-decrement: arr[key]--
  def evaluate_expression_with_state({:array_decrement, array, key_expr}, state) do
    key = evaluate_expression(key_expr, state) |> format_array_key()
    arr = Map.get(state.arrays, array, %{})
    current = Map.get(arr, key, "0") |> parse_number()
    new_arr = Map.put(arr, key, to_string(current - 1))
    new_state = %{state | arrays: Map.put(state.arrays, array, new_arr)}
    {current, new_state}
  end

  # Array element pre-decrement: --arr[key]
  def evaluate_expression_with_state({:array_pre_decrement, array, key_expr}, state) do
    key = evaluate_expression(key_expr, state) |> format_array_key()
    arr = Map.get(state.arrays, array, %{})
    current = Map.get(arr, key, "0") |> parse_number()
    new_val = current - 1
    new_arr = Map.put(arr, key, to_string(new_val))
    new_state = %{state | arrays: Map.put(state.arrays, array, new_arr)}
    {new_val, new_state}
  end

  # getline var < "file" — read next line from file into var
  def evaluate_expression_with_state({:getline, var_name, file_expr, _pipe}, state) do
    file_path =
      case file_expr do
        {:literal, path} -> path
        expr -> to_string(evaluate_expression(expr, state))
      end

    # Resolve path against bash cwd
    resolved = Fs.resolve_path(state.bash.cwd, file_path)

    # Track file read positions in state.variables using a sentinel key
    pos_key = "__getline_pos_#{resolved}__"
    pos = parse_number(Map.get(state.variables, pos_key, "0")) |> trunc()

    case Fs.read_file(state.bash.fs, resolved) do
      {:ok, content} ->
        lines = String.split(content, "\n", trim: true)

        if pos < length(lines) do
          line = Enum.at(lines, pos)

          vars =
            state.variables |> Map.put(var_name, line) |> Map.put(pos_key, to_string(pos + 1))

          {1, %{state | variables: vars}}
        else
          # EOF
          {0, state}
        end

      {:error, _} ->
        {-1, state}
    end
  end

  def evaluate_expression_with_state({:call, "match", args}, state) do
    execute_match(args, state)
  end

  def evaluate_expression_with_state({:call, "split", args}, state) do
    execute_split(args, state)
  end

  def evaluate_expression_with_state({:call, "asorti", args}, state) do
    execute_asorti(args, state)
  end

  def evaluate_expression_with_state({:call, "system", [cmd_expr]}, state) do
    cmd = evaluate_expression(cmd_expr, state) |> to_string()
    {exit_code, state} = execute_system_command(cmd, state)
    {exit_code, state}
  end

  def evaluate_expression_with_state(expr, state) do
    {evaluate_expression(expr, state), state}
  end

  defp get_field(state, 0), do: Enum.at(state.fields, 0, "")

  defp get_field(state, n) when n > 0 do
    Enum.at(state.fields, n, "")
  end

  defp get_field(_state, _n), do: ""

  # Evaluate condition expressions for if statements
  defp evaluate_condition_expr({:==, left, right}, state) do
    left_val = evaluate_expression(left, state)
    right_val = evaluate_expression(right, state)
    # AWK does numeric comparison if both are numbers
    compare_values(left_val, right_val, &==/2)
  end

  defp evaluate_condition_expr({:!=, left, right}, state) do
    left_val = evaluate_expression(left, state)
    right_val = evaluate_expression(right, state)
    compare_values(left_val, right_val, &!=/2)
  end

  defp evaluate_condition_expr({:>, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()
    left_val > right_val
  end

  defp evaluate_condition_expr({:<, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()
    left_val < right_val
  end

  defp evaluate_condition_expr({:>=, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()
    left_val >= right_val
  end

  defp evaluate_condition_expr({:<=, left, right}, state) do
    left_val = evaluate_expression(left, state) |> parse_number()
    right_val = evaluate_expression(right, state) |> parse_number()
    left_val <= right_val
  end

  defp evaluate_condition_expr({:match, expr, pattern}, state) do
    value = evaluate_expression(expr, state) |> to_string()
    pattern_str = unwrap_pattern(pattern)

    case checked_compile(pattern_str, state) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _} -> false
    end
  end

  defp evaluate_condition_expr({:truthy, expr}, state) do
    value = evaluate_expression(expr, state)
    truthy?(value)
  end

  defp evaluate_condition_expr({:not, expr}, state) do
    not truthy?(evaluate_expression(expr, state))
  end

  # Catch-all: evaluate as expression and check truthiness
  defp evaluate_condition_expr(expr, state) do
    truthy?(evaluate_expression(expr, state))
  end

  defp compare_values(left, right, op) do
    # If both can be parsed as numbers, compare numerically
    left_num = parse_number(left)
    right_num = parse_number(right)

    if is_number(left) or is_number(right) or
         (is_binary(left) and is_binary(right) and looks_like_number?(left) and
            looks_like_number?(right)) do
      op.(left_num, right_num)
    else
      op.(to_string(left), to_string(right))
    end
  end

  defp looks_like_number?(s) when is_binary(s), do: s =~ ~r/^\s*-?\d+(\.\d+)?\s*$/
  defp looks_like_number?(_), do: false

  defp truthy?(0), do: false
  defp truthy?(n) when is_float(n) and n == 0.0, do: false
  defp truthy?(""), do: false

  defp truthy?(s) when is_binary(s) do
    # In awk, strings that look like zero are falsy in boolean context
    case Float.parse(String.trim(s)) do
      {val, ""} -> val != 0.0
      _ -> true
    end
  end

  defp truthy?(_), do: true

  # AWK built-in functions
  defp evaluate_function("length", [], state) do
    String.length(Enum.at(state.fields, 0, ""))
  end

  defp evaluate_function("length", [arg], _state) do
    String.length(to_string(arg))
  end

  defp evaluate_function("substr", [str, start], _state) do
    s = to_string(str)
    start_idx = max(0, parse_number(start) |> trunc() |> Kernel.-(1))
    String.slice(s, start_idx..-1//1)
  end

  defp evaluate_function("substr", [str, start, len], _state) do
    s = to_string(str)
    start_idx = max(0, parse_number(start) |> trunc() |> Kernel.-(1))
    length = parse_number(len) |> trunc()
    String.slice(s, start_idx, length)
  end

  defp evaluate_function("tolower", [arg], _state) do
    String.downcase(to_string(arg))
  end

  defp evaluate_function("toupper", [arg], _state) do
    String.upcase(to_string(arg))
  end

  defp evaluate_function("index", [str, substr], _state) do
    s = to_string(str)
    sub = to_string(substr)

    case :binary.match(s, sub) do
      {pos, _} -> pos + 1
      :nomatch -> 0
    end
  end

  defp evaluate_function("split", [str, _array, sep], _state) do
    # Simplified: just return count
    s = to_string(str)
    length(String.split(s, to_string(sep)))
  end

  defp evaluate_function("sprintf", [format | args], _state) do
    Formatter.format_printf(format, args)
  end

  # Math functions
  defp evaluate_function("int", [arg], _state) do
    parse_number(arg) |> trunc()
  end

  defp evaluate_function("sqrt", [arg], _state) do
    :math.sqrt(parse_number(arg))
  end

  defp evaluate_function("sin", [arg], _state) do
    :math.sin(parse_number(arg))
  end

  defp evaluate_function("cos", [arg], _state) do
    :math.cos(parse_number(arg))
  end

  defp evaluate_function("exp", [arg], _state) do
    :math.exp(parse_number(arg))
  end

  defp evaluate_function("log", [arg], _state) do
    :math.log(parse_number(arg))
  end

  defp evaluate_function("atan2", [y, x], _state) do
    :math.atan2(parse_number(y), parse_number(x))
  end

  defp evaluate_function("rand", [], _state) do
    :rand.uniform()
  end

  defp evaluate_function("srand", [], _state) do
    :rand.seed(:default)
    0
  end

  defp evaluate_function("srand", [seed], _state) do
    :rand.seed(:default, {trunc(parse_number(seed)), 0, 0})
    0
  end

  defp evaluate_function("match", [string, pattern], state) do
    regex = compile_awk_regex(to_string(pattern), state)

    case Regex.run(regex, to_string(string), return: :index) do
      nil -> 0
      [{start, _len} | _] -> start + 1
    end
  end

  # asorti is handled via evaluate_expression_with_state for state mutation
  defp evaluate_function("asorti", _args, _state), do: 0

  defp evaluate_function(_name, _args, _state), do: ""

  # Format a value for output - integers print without .0
  # Format array keys: 0.0 -> "0", 1.0 -> "1", "1.0" -> "1", etc.
  defp format_array_key(value) when is_float(value) do
    if trunc(value) == value, do: Integer.to_string(trunc(value)), else: Float.to_string(value)
  end

  defp format_array_key(value) when is_integer(value), do: Integer.to_string(value)

  defp format_array_key(value) when is_binary(value) do
    case Float.parse(value) do
      {num, ""} when trunc(num) == num -> Integer.to_string(trunc(num))
      _ -> value
    end
  end

  defp format_array_key(value), do: to_string(value)

  defp format_output_value(value) when is_float(value) do
    if trunc(value) == value do
      Integer.to_string(trunc(value))
    else
      Float.to_string(value)
    end
  end

  defp format_output_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_output_value(value) when is_binary(value) do
    # Check if string is a whole number float like "6.0" and format as "6"
    # But preserve strings that start with 0 (like "00042") or are not purely numeric
    # Preserve strings starting with 0 (unless it's just "0")
    if String.starts_with?(value, "0") and value != "0" and value =~ ~r/^0\d/ do
      value
    else
      # Handle float-like strings like "6.0" -> "6"
      case Float.parse(value) do
        {num, ""} when trunc(num) == num -> Integer.to_string(trunc(num))
        _ -> value
      end
    end
  end

  defp format_output_value(value), do: to_string(value)

  @doc """
  Parse a value as a number.
  """
  @spec parse_number(any()) :: number()
  def parse_number(value) when is_number(value), do: value

  def parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> n
      :error -> 0.0
    end
  end

  def parse_number(_), do: 0.0

  # Execute a shell command via JustBash.exec, returning {exit_code, updated_state}
  defp execute_system_command(cmd, state) do
    case state.bash do
      nil ->
        # No bash state available, can't execute
        {1, state}

      bash ->
        {result, new_bash} = JustBash.exec(bash, cmd)
        # system() in awk prints stdout to awk's output
        new_output = state.output <> result.stdout
        {result.exit_code, %{state | output: new_output, bash: new_bash}}
    end
  end
end
