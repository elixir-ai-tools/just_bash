defmodule JustBash.Commands.Awk.Evaluator do
  @moduledoc """
  Evaluator for AWK programs.

  Executes parsed AWK programs against input content, managing state
  and producing output.
  """

  alias JustBash.Commands.Awk.{Formatter, Parser}

  @type state :: %{
          nr: non_neg_integer(),
          nf: non_neg_integer(),
          fs: String.t(),
          ofs: String.t(),
          ors: String.t(),
          fields: [String.t()],
          variables: %{String.t() => String.t()},
          output: String.t()
        }

  @doc """
  Execute an AWK program against the given content.

  Returns the output string.
  """
  @spec execute(String.t(), Parser.program(), %{field_separator: String.t(), variables: map()}) ::
          String.t()
  def execute(content, program, opts) do
    lines = String.split(content, "\n", trim: false)

    lines =
      if List.last(lines) == "" do
        List.delete_at(lines, -1)
      else
        lines
      end

    state = %{
      nr: 0,
      nf: 0,
      fs: opts.field_separator,
      ofs: " ",
      ors: "\n",
      fields: [],
      variables: opts.variables,
      output: ""
    }

    state = execute_begin_blocks(state, program.begin_blocks)

    state =
      Enum.reduce(lines, state, fn line, s ->
        process_line(line, program.main_rules, s)
      end)

    state = execute_end_blocks(state, program.end_blocks)

    state.output
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
        nf: length(fields),
        fields: [line | fields]
    }

    if rules == [] do
      state
    else
      Enum.reduce(rules, state, &apply_rule/2)
    end
  end

  defp apply_rule({pattern, action}, state) do
    if pattern_matches?(pattern, state) do
      execute_statements(action, state)
    else
      state
    end
  end

  defp split_fields(line, fs) do
    if fs == " " do
      String.split(line, ~r/\s+/, trim: true)
    else
      String.split(line, fs)
    end
  end

  defp pattern_matches?(nil, _state), do: true

  defp pattern_matches?({:regex, pattern}, state) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, Enum.at(state.fields, 0, ""))
      {:error, _} -> false
    end
  end

  defp pattern_matches?({:condition, condition}, state) do
    evaluate_condition(condition, state)
  end

  defp evaluate_condition(condition, state) do
    case evaluate_nr_condition(condition, state) do
      nil -> evaluate_field_or_default(condition, state)
      result -> result
    end
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

    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, field_value)
      {:error, _} -> false
    end
  end

  defp execute_statements(statements, state) do
    Enum.reduce(statements, state, &execute_statement/2)
  end

  defp execute_statement(nil, state), do: state

  defp execute_statement({:print, args}, state) do
    values = Enum.map(args, &evaluate_expression(&1, state))
    formatted = Enum.map(values, &format_output_value/1)
    output_line = Enum.join(formatted, state.ofs) <> state.ors
    %{state | output: state.output <> output_line}
  end

  defp execute_statement({:printf, {format, args}}, state) do
    values = Enum.map(args, &evaluate_expression(&1, state))
    output = Formatter.format_printf(format, values)
    %{state | output: state.output <> output}
  end

  defp execute_statement({:assign, var, expr}, state) do
    value = evaluate_expression(expr, state) |> to_string()

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

    case Regex.compile(pattern) do
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

    case Regex.compile(pattern) do
      {:ok, regex} ->
        new_val = Regex.replace(regex, field_val, replacement)
        new_fields = List.replace_at(state.fields, n, new_val)
        %{state | fields: new_fields}

      {:error, _} ->
        state
    end
  end

  # sub(/pattern/, "replacement", target) - replace first occurrence only
  defp execute_statement({:sub, pattern, replacement, {:field, 0}}, state) do
    line = Enum.at(state.fields, 0, "")

    case Regex.compile(pattern) do
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

    case Regex.compile(pattern) do
      {:ok, regex} ->
        new_val = Regex.replace(regex, field_val, replacement, global: false)
        new_fields = List.replace_at(state.fields, n, new_val)
        %{state | fields: new_fields}

      {:error, _} ->
        state
    end
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
      case Map.get(state.variables, var_name) do
        nil -> 0
        v -> parse_number(v) |> trunc()
      end

    get_field(state, n)
  end

  def evaluate_expression({:variable, "NR"}, state), do: state.nr
  def evaluate_expression({:variable, "NF"}, state), do: state.nf
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

    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _} -> false
    end
  end

  defp evaluate_condition_expr({:truthy, expr}, state) do
    value = evaluate_expression(expr, state)
    truthy?(value)
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
  defp truthy?("0"), do: false
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

  defp evaluate_function(_name, _args, _state), do: ""

  # Format a value for output - integers print without .0
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
    case Float.parse(value) do
      {num, ""} when trunc(num) == num -> Integer.to_string(trunc(num))
      _ -> value
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
end
