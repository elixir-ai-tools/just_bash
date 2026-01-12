defmodule JustBash.Commands.Awk.Evaluator do
  @moduledoc """
  Evaluator for AWK programs.

  Executes parsed AWK programs against input content, managing state
  and producing output.
  """

  alias JustBash.Commands.Awk.{Parser, Formatter}

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
      Enum.reduce(rules, state, fn {pattern, action}, s ->
        if pattern_matches?(pattern, s) do
          execute_statements(action, s)
        else
          s
        end
      end)
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
    cond do
      condition =~ ~r/^NR\s*==\s*(\d+)$/ ->
        [_, n] = Regex.run(~r/^NR\s*==\s*(\d+)$/, condition)
        state.nr == String.to_integer(n)

      condition =~ ~r/^NR\s*>\s*(\d+)$/ ->
        [_, n] = Regex.run(~r/^NR\s*>\s*(\d+)$/, condition)
        state.nr > String.to_integer(n)

      condition =~ ~r/^NR\s*<\s*(\d+)$/ ->
        [_, n] = Regex.run(~r/^NR\s*<\s*(\d+)$/, condition)
        state.nr < String.to_integer(n)

      condition =~ ~r/^NR\s*>=\s*(\d+)$/ ->
        [_, n] = Regex.run(~r/^NR\s*>=\s*(\d+)$/, condition)
        state.nr >= String.to_integer(n)

      condition =~ ~r/^NR\s*<=\s*(\d+)$/ ->
        [_, n] = Regex.run(~r/^NR\s*<=\s*(\d+)$/, condition)
        state.nr <= String.to_integer(n)

      condition =~ ~r/^\$(\d+)\s*==\s*"([^"]*)"$/ ->
        [_, field_str, value] = Regex.run(~r/^\$(\d+)\s*==\s*"([^"]*)"$/, condition)
        field = String.to_integer(field_str)
        get_field(state, field) == value

      condition =~ ~r/^\$(\d+)\s*~\s*\/([^\/]*)\/\s*$/ ->
        [_, field_str, pattern] = Regex.run(~r/^\$(\d+)\s*~\s*\/([^\/]*)\/\s*$/, condition)
        field = String.to_integer(field_str)
        field_value = get_field(state, field)

        case Regex.compile(pattern) do
          {:ok, regex} -> Regex.match?(regex, field_value)
          {:error, _} -> false
        end

      true ->
        true
    end
  end

  defp execute_statements(statements, state) do
    Enum.reduce(statements, state, &execute_statement/2)
  end

  defp execute_statement(nil, state), do: state

  defp execute_statement({:print, args}, state) do
    values = Enum.map(args, &evaluate_expression(&1, state))
    output_line = Enum.join(values, state.ofs) <> state.ors
    %{state | output: state.output <> output_line}
  end

  defp execute_statement({:printf, {format, args}}, state) do
    values = Enum.map(args, &evaluate_expression(&1, state))
    output = Formatter.format_printf(format, values)
    %{state | output: state.output <> output}
  end

  defp execute_statement({:assign, var, expr}, state) do
    value = evaluate_expression(expr, state)
    %{state | variables: Map.put(state.variables, var, to_string(value))}
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

  defp get_field(state, 0), do: Enum.at(state.fields, 0, "")

  defp get_field(state, n) when n > 0 do
    Enum.at(state.fields, n, "")
  end

  defp get_field(_state, _n), do: ""

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
